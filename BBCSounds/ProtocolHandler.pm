package Plugins::BBCSounds::ProtocolHandler;

#  stu@expectingtofly.co.uk
#  An adapted version (MPD Handling) of Plugins::YouTube::ProtocolHandler by philippe_44@outlook.com
#
#  This program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 3 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program; if not, write to the Free Software
#  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
#  MA 02110-1301, USA.
#

use base qw(IO::Handle);

use strict;

use List::Util qw(min max first);
use HTML::Parser;
use HTML::Entities;
use HTTP::Date;
use URI;
use URI::Escape;
use URI::Split;
use Scalar::Util qw(blessed);
use JSON::XS;
use Data::Dumper;
use File::Spec::Functions;
use File::Basename;
use FindBin qw($Bin);
use XML::Simple;
use POSIX;

use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Errno;
use Slim::Utils::Cache;

use Plugins::BBCSounds::M4a;
use Plugins::BBCSounds::BBCSoundsFeeder;


use constant MIN_OUT    => 8192;
use constant DATA_CHUNK => 128 * 1024;

my $log   = logger('plugin.bbcsounds');
my $cache = Slim::Utils::Cache->new;
my $prefs = preferences('plugin.bbcsounds');


Slim::Player::ProtocolHandlers->registerHandler( 'sounds', __PACKAGE__ );

sub flushCache { $cache->cleanup(); }

my $setProperties  = { 'aac' => \&Plugins::BBCSounds::M4a::setProperties };
my $getAudio       = { 'aac' => \&Plugins::BBCSounds::M4a::getAudio };
my $getStartOffset = { 'aac' => \&Plugins::BBCSounds::M4a::getStartOffset };


sub canDoAction {
	my ( $class, $client, $url, $action ) = @_;

	main::INFOLOG && $log->is_info && $log->info("action=$action");
	if ( $action eq 'pause' ) {
		if (!($class->isLive($url))) {
			Plugins::BBCSounds::ActivityManagement::heartBeat(Plugins::BBCSounds::ProtocolHandler->getId($url),Plugins::BBCSounds::ProtocolHandler->getPid($url),'paused',floor($client->playingSong()->master->controller->playingSongElapsed));
		}
	}

	if ($class->isLive($url)) {
		if ($action eq 'stop') { #skip to next track
			 #only allow skiping if we have an end number and it is in the past
			my $song = $client->playingSong();
			my $props = $song->pluginData('props');

			main::INFOLOG && $log->is_info && $log->info('Skipping forward when end number is ' . $props->{endNumber});

			#is the current endNumber in the past?
			if ($props->{endNumber} > 0) {
				if (Time::HiRes::time() > ($class->_timeFromOffset($props->{endNumber},$props)+10)){
					return 1;
				}

				#force it to reload and therefore return to live
				$props->{isDynamic} = 0;
				$song->pluginData( props   => $props );
				return 1;
			}
			return 0; #not ready to know what to do.
		}
		if ($action eq 'rew') { #skip back to start of track
			 # make sure start number is correct for the programme (if we have it)
			my $song = $client->playingSong();
			my $props = $song->pluginData('props');
			$props->{comparisonTime} -= (($props->{startNumber} - $props->{virtualStartNumber})) * ($props->{segmentDuration} / $props->{segmentTimescale});
			$props->{startNumber} = $props->{virtualStartNumber};
			$song->pluginData( props   => $props );
			return 1;
		}
	}

	return 1;
}


sub new {
	my $class = shift;
	my $args  = shift;
	my $song  = $args->{'song'};
	my $offset;
	my $props = $song->pluginData('props');

	my $masterUrl = $song->track()->url;

	return undef if !defined $props;

	# erase last position from cache
	$cache->remove( "bs:lastpos-" . $class->getId($masterUrl) );

	$args->{'url'} = $song->pluginData('baseURL');

	my $seekdata =$song->can('seekdata') ? $song->seekdata : $song->{'seekdata'};
	my $startTime = $seekdata->{'timeOffset'} || $class->getLastPos($masterUrl);
	$song->pluginData( 'lastpos', 0 );

	if ($startTime) {

		if ($props->{isDynamic}) {

			#we can't go into the future
			my $edge = $class->_calculateEdgeFromTime(Time::HiRes::time(),$props);
			my $maxStartTime = $edge - ($props->{virtualStartNumber} * ($props->{segmentDuration} / $props->{segmentTimescale}));

			#Remove a chunk to provide safety margin and less wait time on restart
			$maxStartTime -= ($props->{segmentDuration} / $props->{segmentTimescale});

			$startTime = $maxStartTime if ($startTime > $maxStartTime);

			#This "song" has a maximum age
			my $maximumAge = 18000;  # 5 hours
			if ((Time::HiRes::time() - $props->{comparisonTime}) > $maximumAge) {

				#we need to end this track and let it rise again
				$log->error('Live stream to old after pause, stopping the continuation.');
				$props->{isDynamic} = 0;
				$song->pluginData( props   => $props );
				return;
			}
		}

		$song->can('startOffset')
		  ? $song->startOffset($startTime)
		  : ( $song->{startOffset} = $startTime );

		my $remote = Time::HiRes::time() - $startTime;
		main::INFOLOG && $log->is_info && $log->info( "Remote Stream Start Time = " . $remote );
		$args->{'client'}->master->remoteStreamStartTime($remote);
		$offset = undef;
	}

	main::INFOLOG
	  && $log->is_info
	  && $log->info( "url: $args->{url} master: $masterUrl offset: ",$startTime|| 0 );

	my $self = $class->SUPER::new;

	if ( defined($self) ) {
		${*$self}{'client'} = $args->{'client'};
		${*$self}{'song'}   = $args->{'song'};
		${*$self}{'url'}    = $args->{'url'};
		${*$self}{'props'}  = $props;
		${*$self}{'vars'} = {    # variables which hold state for this instance:
			'inBuf'  => '',      # buffer of received data
			'outBuf' => '',      # buffer of processed audio
			'streaming' =>1,    # flag for streaming, changes to 0 when all data received
			'fetching' => 0,        # waiting for HTTP data
			'offset'   => $offset, # offset for next HTTP request in webm/stream or segment index in dash
			'endOffset' => $props->{endNumber}, #the end number of this track.
			'resetMeta'=> 1,
			'liveId'   => '',  # The ID of the live programme playing
			'trackData' => {   # For managing showing live track data
				'chunkCounter' => 0,   # for managing showing show title or track in a 4/2 regime
				'isShowingTitle' => 0,   # indicates what cycle we are on
				'awaitingCb' => 0      #flag for callback on track data
			},
			'nextHeartbeat' =>  time() + 30   #AOD data sends a heartbeat to the BBC
		};
	}

	# set starting offset (bytes or index) if not defined yet
	$getStartOffset->{ $props->{'format'} }(
		$args->{url},
		$startTime,
		$props,
		sub {
			${*$self}{'vars'}->{offset} = shift;
			$log->info( "starting from offset ", ${*$self}{'vars'}->{offset} );
		}
	) if !defined $offset;

	# set timer for updating the MPD if needed (dash)
	${*$self}{'active'} = 1;    #SM Removed timer


	return $self;
}


sub close {
	my $self = shift;

	${*$self}{'active'} = 0;

	main::INFOLOG && $log->is_info && $log->info('close called');


	my $props    = ${*$self}{'props'};

	if ($props->{isDynamic}) {
		my $song      = ${*$self}{'song'};
		my $v        = $self->vars;

		#make sure we don't try and continue if we were streaming when it is started again.
		if ($v->{streaming}) {
			$props->{isDynamic} = 0;
			$song->pluginData( props   => $props );
			main::INFOLOG && $log->info("Ensuring live stream closed");
		}
	}


	$self->SUPER::close(@_);
}


sub onStop {
	my ( $class, $song ) = @_;
	my $elapsed = $song->master->controller->playingSongElapsed;
	my $id = Plugins::BBCSounds::ProtocolHandler->getId( $song->track->url );


	if (!($class->isLive($song->track->url))) {
		Plugins::BBCSounds::ActivityManagement::heartBeat( $id,Plugins::BBCSounds::ProtocolHandler->getPid( $song->track->url ),'paused', floor($elapsed) );
	}

	if ( $elapsed < $song->duration - 15 ) {
		$cache->set( "bs:lastpos-$id", int($elapsed), '30days' );
		$log->info("Last position for $id is $elapsed");
	}else {
		$cache->remove("bs:lastpos-$id");
	}
}


sub onStream {
	my ( $class, $client, $song ) = @_;
	my $url  = $song->track->url;
	my $id   = Plugins::BBCSounds::ProtocolHandler->getId($url);
	my $meta = $cache->get("bs:meta-$id") || {};

	#perform starting heartbeat
	if (!($class->isLive($url))) {
		Plugins::BBCSounds::ActivityManagement::heartBeat($id,       Plugins::BBCSounds::ProtocolHandler->getPid($url),'started', floor( $song->master->controller->playingSongElapsed ));
	}


}


sub formatOverride {
	return $_[1]->pluginData('props')->{'format'};
}


sub contentType {
	return ${ *{ $_[0] } }{'props'}->{'format'};
}

sub isAudio { 1 }

sub isRemote { 1 }

sub canDirectStream { 0 }

sub songBytes { }

sub canSeek { 1 }


sub getSeekData {
	my ( $class, $client, $song, $newtime ) = @_;

	main::INFOLOG && $log->info( 'Trying to seek ' . $newtime . ' seconds for offset ' . $song->track->audio_offset );

	return { timeOffset => $newtime };
}


sub vars {
	return ${ *{ $_[0] } }{'vars'};
}

my $nextWarning = 0;


sub liveTrackData {
	my $self = shift;
	my $client = ${*$self}{'client'};
	my $v = $self->vars;

	#if endoffset is still 0, leave as we don't have a meta data yet.
	return if $v->{'endOffset'} == 0;

	my $song  = ${*$self}{'song'};
	my $masterUrl = $song->track()->url;
	my $station = _getStationID($masterUrl);

	$v->{'trackData'}->{chunkCounter}++;

	# we must leave if we have a title waiting to be changed by buffer callback
	return if $v->{'trackData'}->{awaitingCb};

	if ($v->{'trackData'}->{isShowingTitle}) {

		#we only need to reset the title if we have gone forward 2
		return if ($v->{'trackData'}->{chunkCounter} < 3);
		$v->{'trackData'}->{awaitingCb} = 1;
		$v->{'trackData'}->{isShowingTitle} = 0;
		$v->{'trackData'}->{chunkCounter} = 1;


		my $meta = $song->pluginData('meta');
		$meta->{title} = $meta->{realTitle};
		$meta->{icon} = $meta->{realIcon};
		$meta->{cover} = $meta->{realCover};
		$song->pluginData( meta  => $meta );

		my $cb = sub {
			main::INFOLOG && $log->is_info && $log->info("Setting title back after callback");
			Slim::Control::Request::notifyFromArray( $client, ['newmetadata'] );
			$v->{'trackData'}->{awaitingCb} = 0;
		};

		#the title will be set when the current buffer is done
		Slim::Music::Info::setDelayedCallback( $client, $cb, 'output-only' );


	}else{
		#we only need to set the title if we have gone forward 4 chunks
		return if $v->{'trackData'}->{chunkCounter} < 5;

		$v->{'trackData'}->{awaitingCb} = 1;
		$v->{'trackData'}->{isShowingTitle} = 1;
		$v->{'trackData'}->{chunkCounter} = 1;


		my $props =  ${*$self}{'props'};

		my $sub;

		if ($self->isLive($masterUrl)) {
			$sub = sub {
				my $cbY = shift;
				my $cbN = shift;
				_getLiveTrack(_getStationID($masterUrl), $self->_timeFromOffset( $v->{'offset'}, $props) - $self->_timeFromOffset($props->{virtualStartNumber},$props),$cbY,$cbN);
			};
		} else {
			$sub = sub {
				my $cbY = shift;
				my $cbN = shift;
				_getAODTrack($self->getId($masterUrl), $self->_timeFromOffset( $v->{'offset'}, $props),$cbY,$cbN);
			};
		}


		$sub->(
			sub {
				my $track = shift;
				my $meta = $song->pluginData('meta');
				if ($track->{total} == 0) {

					#nothing there
					$meta->{album} = '';
					$meta->{spotify} = '';
					$song->pluginData( meta  => $meta );

					$v->{'trackData'}->{isShowingTitle} = 0;
					$v->{'trackData'}->{awaitingCb} = 0;
					return;
				} else {

					if ($self->isLive($masterUrl) && (($self->_timeFromOffset($props->{virtualStartNumber},$props) + $track->{data}[0]->{start}) > $self->_timeFromOffset( $v->{'offset'}, $props))) {

						main::INFOLOG && $log->is_info && $log->info("Have new title but not playing yet");

						#The track hasn't started yet. leave.
						$meta->{album} = '';
						$meta->{spotify} = '';
						$song->pluginData( meta  => $meta );

						$v->{'trackData'}->{isShowingTitle} = 0;
						$v->{'trackData'}->{awaitingCb} = 0;
						return;
					}

					my $newTitle = $track->{data}[0]->{titles}->{secondary} . ' by ' . $track->{data}[0]->{titles}->{primary};
					$meta->{title} = $newTitle;
					$meta->{album} = 'Now Playing : ' . $newTitle;
					if (my $image = $track->{data}[0]->{image_url}) {
						$image =~ s/{recipe}/320x320/;
						$meta->{icon} = $image;
						$meta->{cover} = $image;
					}

					#add a spotify id if there is one
					my $spotifyId = '';
					main::INFOLOG && $log->is_info && $log->info('Music service link count ' . scalar @{$track->{data}[0]->{uris}} );

					for my $uri (@{$track->{data}[0]->{uris}}) {
						if ($uri->{label} eq 'Spotify') {
							$spotifyId = $uri->{uri};
							$spotifyId =~ s/https:\/\/open.spotify.com\/track\//spotify:\/\/track:/;
							last;
						}
					}
					$meta->{spotify} = $spotifyId;

					$song->pluginData( meta  => $meta );

					main::INFOLOG && $log->is_info && $log->info("Setting new live title $newTitle");
					my $cb = sub {
						main::INFOLOG && $log->is_info && $log->info("Setting new live title after callback $newTitle");
						Slim::Control::Request::notifyFromArray( $client, ['newmetadata'] );
						$v->{'trackData'}->{awaitingCb} = 0;
					};

					#the title will be set when the current buffer is done
					Slim::Music::Info::setDelayedCallback( $client, $cb, 'output-only' );

				}
			},
			sub {
				# an error occured
				$v->{'trackData'}->{isShowingTitle} = 0;
				$v->{'trackData'}->{awaitingCb} = 0;
				$log->warn('Failed to retrieve live track data');
			}
		);
	}
}


sub aodMetaData {
	my $self = shift;
	my $client = ${*$self}{'client'};
	my $v        = $self->vars;
	my $song      = ${*$self}{'song'};
	my $masterUrl = $song->track()->url;
	my $pid =   $self->getPid($masterUrl);


	_getAODMeta(
		$pid,
		sub {
			my $retMeta = shift;
			$song->pluginData( meta  => $retMeta );
			$v->{'resetMeta'} = 0;
			Slim::Control::Request::notifyFromArray( $client, ['newmetadata'] );
		},
		sub {
			$log->warn('Could not retrieve AOD meta data ' . $pid);
		}

	);
	return;
}


sub liveMetaData {
	my $self = shift;
	my $client = ${*$self}{'client'};
	my $v        = $self->vars;
	my $song      = ${*$self}{'song'};
	my $masterUrl = $song->track()->url;
	my $station = _getStationID($masterUrl);

	main::INFOLOG && $log->is_info && $log->info('Checking for new live meta data');

	_getLiveSchedule(
		$station, ${*$self}{'props'},

		#success schedule
		sub {
			my $schedule = shift;
			my $resp = _getIDForBroadcast($schedule, $v->{'offset'}, ${*$self}{'props'});
			my $id = '';
			if ($resp){
				$id = $resp->{id};
			}
			if (!($id eq $v->{'liveId'})) {
				$v->{'liveId'} = $id;
				main::INFOLOG && $log->is_info && $log->info('New meta required ' . $id . ' seconds ' . $resp->{secondsIn} .  ' now ' .  $v->{'offset'} . ' end offset ' . $resp->{endOffset});
				_getLiveMeta(
					$id,

					#success meta
					sub {
						my $retMeta = shift;
						main::DEBUGLOG && $log->is_debug && $log->debug('Setting Title to ' .$retMeta->{title});
						$song->pluginData( meta  => $retMeta );

						#fix progress bar
						$client->playingSong()->can('startOffset')
						  ? $client->playingSong()->startOffset($resp->{secondsIn})
						  : ( $client->playingSong()->{startOffset} = $resp->{secondsIn} );
						$client->master()->remoteStreamStartTime( Time::HiRes::time() - $resp->{secondsIn} );
						$client->playingSong()->duration( $retMeta->{duration} );

						#we can now set the end point for this
						$v->{'endOffset'} = $resp->{endOffset};
						$v->{'resetMeta'} = 0;

						#update in the props
						my $props      = ${*$self}{'props'};
						$props->{endNumber} = $resp->{endOffset};
						$props->{virtualStartNumber} = $resp->{startOffset};

						#ensure plug in data up to date
						$song->pluginData( props   => $props );

						Slim::Control::Request::notifyFromArray( $client, ['newmetadata'] );

						main::INFOLOG && $log->is_info && $log->info('Set Offsets '  . $props->{'virtualStartNumber'} . ' ' . $v->{'endOffset'} . ' for '. $id);
					},

					#failed
					sub {
						$log->warn('Could not retrieve live meta data ' . $masterUrl);
						$v->{'resetMeta'} = 0;
					}
				);
			}
		},
		sub {
			$log->warn('Could not retrieve station schedule');
		}
	);
}


sub _calculateEdge {
	my ( $class, $currentOffset, $props) = @_;

	my $seglength = ($props->{segmentDuration} / $props->{segmentTimescale});
	my $edge = ($currentOffset - $props->{startNumber}) * $seglength;
	$edge += ($props->{comparisonTime} - $seglength);

	return $edge;

}


sub _timeFromOffset {
	my ( $class, $currentOffset, $props) = @_;
	my $seglength = ($props->{segmentDuration} / $props->{segmentTimescale});
	return ($currentOffset * $seglength);
}


sub _calculateEdgeFromTime {
	my ( $class, $currentTime, $props) = @_;

	my $seglength = ($props->{segmentDuration} / $props->{segmentTimescale});

	return $class->_calculateEdge(floor($currentTime / $seglength),$props);

}


sub sysread {
	use bytes;

	my $self = $_[0];

	# return in $_[1]
	my $maxBytes = $_[2];
	my $v        = $self->vars;
	my $baseURL  = ${*$self}{'url'};
	my $props    = ${*$self}{'props'};
	my $song      = ${*$self}{'song'};
	my $masterUrl = $song->track()->url;

	# means waiting for offset to be set
	if ( !defined $v->{offset} ) {
		$! = EINTR;
		return undef;
	}


	# need more data
	if (   length $v->{'outBuf'} < MIN_OUT
		&& !$v->{'fetching'}
		&& $v->{'streaming'} ) {
		my $url = $baseURL;
		my @range;
		if ($props->{isDynamic}) {
			main::INFOLOG && $log->is_info && $log->info('Need More data, we have ' . length $v->{'outBuf'} . ' in the buffer');

			#check if we can get more if not leave
			my $edge = $self->_calculateEdge($v->{'offset'}, $props);
			main::DEBUGLOG && $log->is_debug && $log->debug('Edge = ' . $edge . ' Now : '. Time::HiRes::time());
			if ($edge > Time::HiRes::time()){

				#bail
				main::INFOLOG && $log->is_info && $log->info('Data not yet available for '  . $v->{'offset'} . ' now ' . Time::HiRes::time() . ' edge ' . $edge );
				$! = EINTR;
				return undef;
			}
		}
		main::INFOLOG && $log->is_info && $log->info("Fetching " . $v->{'offset'} . ' towards the end of '. $v->{'endOffset'} );


		$url .= $props->{'segmentURL'};
		my $replOffset = ( $v->{'offset'} );

		$url =~ s/\$Number\$/$replOffset/;
		$v->{'offset'}++;

		$v->{'fetching'} = 1;

		Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				$v->{'inBuf'} .= $_[0]->content;
				$v->{'fetching'} = 0;

				$v->{'streaming'} = 0
				  if ($v->{'endOffset'} > 0) && ($v->{'offset'} > $v->{'endOffset'});

				main::DEBUGLOG && $log->is_debug && $log->debug("got chunk $v->{'offset'} length: ",length $_[0]->content," for $url");

				if ($self->isLive($masterUrl)) {

					# get the meta data for this live track if we don't have it yet.
					$self->liveMetaData() if ($v->{'endOffset'} == 0  || $v->{'resetMeta'} == 1);

					# check for live track if we are within striking distance of the live edge
					my $edge = $self->_calculateEdge($v->{'offset'}, $props);
					$self->liveTrackData() if (Time::HiRes::time()-$edge) < 30;
				}else{
					$self->aodMetaData() if ($v->{'resetMeta'} == 1);
					$self->liveTrackData();
				}


			},

			sub {
				if ( main::DEBUGLOG && $log->is_debug ) {
					$log->debug("error fetching $url");
				}


				# only log error every x seconds - it's too noisy for regular use
				elsif ( time() > $nextWarning ) {
					$log->warn("error fetching $url");
					$nextWarning = time() + 10;
				}

				$v->{'inBuf'}    = '';
				$v->{'fetching'} = 0;
				$v->{'streaming'} = 0
				  if ($v->{'endOffset'} > 0) && ($v->{'offset'} > $v->{'endOffset'});

			},

		)->get( $url, @range );
	}

	# process all available data
	$getAudio->{ $props->{'format'} }( $v, $props ) if length $v->{'inBuf'};

	if ( my $bytes = min( length $v->{'outBuf'}, $maxBytes ) ) {
		$_[1] = substr( $v->{'outBuf'}, 0, $bytes );
		$v->{'outBuf'} = substr( $v->{'outBuf'}, $bytes );
		main::DEBUGLOG && $log->is_debug && $log->debug('Bytes . ' . Time::HiRes::time());
		return $bytes;
	} elsif ( $v->{'streaming'} || $props->{'updatePeriod'} ) {

		#bbc heartbeat at a quiet time.
		if (!($self->isLive($masterUrl))) {
			if ( time() > $v->{nextHeartbeat} ) {
				Plugins::BBCSounds::ActivityManagement::heartBeat(Plugins::BBCSounds::ProtocolHandler->getId($masterUrl),Plugins::BBCSounds::ProtocolHandler->getPid($masterUrl),'heartbeat',floor( $song->master->controller->playingSongElapsed ));
				$v->{nextHeartbeat} = time() + 30;
			}
		}
		$! = EINTR;
		return undef;
	}

	# end of streaming and make sure timer is not running
	main::INFOLOG && $log->is_info && $log->info("end streaming");
	$props->{'updatePeriod'} = 0;

	return 0;
}


sub getId {
	my ( $class, $url ) = @_;

	my @pid  = split /_/x, $url;
	my $vpid =  @pid[1];
	if ($vpid eq 'LIVE') {
		@pid  = split /_LIVE_/x, $url;
		$vpid =  @pid[1];
	}

	return $vpid;
}


sub getPid {
	my ( $class, $url ) = @_;

	my @pid = split /_/x, $url;
	my $pid  = @pid[2];

	return $pid;
}


sub getLastPos {
	my ( $class, $url ) = @_;
	my $lastpos = 0;
	my @pid = split /_/x, $url;
	if ((scalar @pid) == 4) {
		$lastpos = @pid[3];
	}
	return $lastpos;
}


# fetch the Sounds player url and extract a playable stream
sub getNextTrack {
	my ( $class, $song, $successCb, $errorCb ) = @_;
	my $masterUrl = $song->track()->url;
	main::INFOLOG && $log->is_info && $log->info("Request for next track " . $masterUrl);


	$song->pluginData( lastpos => ( $masterUrl =~ /&lastpos=([\d]+)/ )[0]|| 0 );
	$masterUrl =~ s/&.*//;

	my $url ='';


	my $processMPD = sub {

		my @allowDASH = ();

		main::INFOLOG
		  && $log->is_info
		  && $log->info("url: $url master: $masterUrl");

		push @allowDASH,([ 'audio_eng=320000',  'aac', 320_000 ],[ 'audio_eng=128000',  'aac', 128_000 ],[ 'audio_eng_1=96000', 'aac', 96_000 ],[ 'audio_eng_1=48000', 'aac', 48_000 ]);
		push @allowDASH,([ 'audio=320000',  'aac', 320_000 ],[ 'audio=128000',  'aac', 128_000 ],[ 'audio=96000', 'aac', 96_000 ],[ 'audio=48000', 'aac', 48_000 ]);
		push @allowDASH,([ 'audio_eng=96000', 'aac', 96_000 ],[ 'audio_eng=48000', 'aac', 48_000 ]);
		@allowDASH = sort { @$a[2] < @$b[2] } @allowDASH;

		my $dashmpd = $url;
		getMPD(
			$dashmpd,
			\@allowDASH,
			sub {
				my $props = shift;
				return $errorCb->() unless $props;
				$song->pluginData( props   => $props );
				$song->pluginData( baseURL => $props->{'baseURL'} );
				$setProperties->{ $props->{'format'} }( $song, $props, $successCb );
			}
		);
	};


	if ($class->isLive($masterUrl)) {

		my $stationid = _getStationID($masterUrl);


		#if we already have props then this is a continuation
		if (my $existingProps = $song->pluginData('props')) {
			if ( $existingProps->{isDynamic}) {
				return errorCb->() unless ($existingProps->{endNumber} > 0);
				$existingProps->{comparisonTime} += (($existingProps->{endNumber} - $existingProps->{startNumber}) + 1) * ($existingProps->{segmentDuration} / $existingProps->{segmentTimescale});
				$existingProps->{startNumber} = $existingProps->{endNumber} + 1;
				$existingProps->{virtualStartNumber} = $existingProps->{startNumber};
				$existingProps->{endNumber} = 0;
				$song->pluginData( props   => $existingProps );

				# reset the meta
				$song->pluginData(meta => undef);

				main::INFOLOG && $log->is_info && $log->info("Continuation  of $masterUrl at " .$existingProps->{startNumber} );
				$successCb->();
				return;
			}
		}
		$song->pluginData(
			meta => {
				type  => 'BBCSounds',
				title => $stationid,
				icon  => $class->getIcon(),
			}
		);

		_getLiveMPDUrl(
			$stationid,
			sub {
				$url = shift;
				$processMPD->();
			},
			sub {
				$log->error('Failed to get live MPD');
				errorCb->();
			}
		);


	}else{

		my $id = $class->getId($masterUrl);
		$url ='http://open.live.bbc.co.uk/mediaselector/6/redir/version/2.0/mediaset/audio-syndication-dash/proto/http/vpid/'. $id;
		$processMPD->();
	}
}


sub getMPD {
	my ( $dashmpd, $allow, $cb ) = @_;

	my $session = Slim::Networking::Async::HTTP->new;
	my $mpdrequest = HTTP::Request->new( GET => $dashmpd );

	$session->send_request(
		{
			request => $mpdrequest,
			onBody  => sub {
				my ( $http, $self ) = @_;
				my $res = $http->response;
				my $req = $http->request;

				my $endURI = URI->new( $res->base );

				main::INFOLOG
				  && $log->is_info
				  && $log->info("Parsing MPD");


				my $selIndex;
				my ( $selRepres, $selAdapt );
				my $mpd = XMLin(
					$res->content,
					KeyAttr      => [],
					ForceContent => 1,
					ForceArray =>[ 'AdaptationSet', 'Representation', 'Period' ]
				);

				#if not dynamic then we start from a relative position.
				my $startBase = '';
				if ($mpd->{'type'} eq 'static') {
					$startBase ='http://' . $endURI->host . dirname( $endURI->path ) . '/';
				}

				my $period        = $mpd->{'Period'}[0];
				my $adaptationSet = $period->{'AdaptationSet'};

				$log->error("Only one period supported")
				  if @{ $mpd->{'Period'} } != 1;

				# find suitable format, first preferred
				foreach my $adaptation (@$adaptationSet) {
					if ( $adaptation->{'mimeType'} eq 'audio/mp4' ) {

						foreach my $representation (@{ $adaptation->{'Representation'} } ){

							next
							  unless my ($index) =
							  grep { $$allow[$_][0] eq $representation->{'id'} }( 0 .. @$allow - 1 );
							main::INFOLOG
							  && $log->is_info
							  && $log->info("found matching format $representation->{'id'}");
							next
							  unless !defined $selIndex || $index < $selIndex;
							$selIndex  = $index;
							$selRepres = $representation;
							$selAdapt  = $adaptation;
						}
					}
				}

				# might not have found anything
				return $cb->() unless $selRepres;
				main::INFOLOG
				  && $log->is_info
				  && $log->info("selected $selRepres->{'id'}");

				my $timeShiftDepth	= $mpd->{'timeShiftBufferDepth'};
				my ($misc, $hour, $min, $sec) = $timeShiftDepth =~ /P(?:([^T]*))T(?:(\d+)H)?(?:(\d+)M)?(?:([+-]?([0-9]*[.])?[0-9]+)S)?/;
				$timeShiftDepth	= ($sec || 0) + (($min || 0) * 60) + (($hour || 0) * 3600);

				my $duration = 0;

				if (defined $mpd->{'mediaPresentationDuration'}) {
					$duration = $mpd->{'mediaPresentationDuration'};
					my ( $misc, $hour, $min, $sec ) = $duration =~/P(?:([^T]*))T(?:(\d+)H)?(?:(\d+)M)?(?:([+-]?([0-9]*[.])?[0-9]+)S)?/;
					$duration =( $sec || 0 ) +( ( $min  || 0 ) * 60 ) +( ( $hour || 0 ) * 3600 );
				}

				my $timescale = $selAdapt->{'SegmentTemplate'}->{'timescale'};

				my $props = {
					format       => $$allow[$selIndex][1],
					isDynamic  =>  ($mpd->{'type'} eq 'dynamic'),
					updatePeriod => 0,
					baseURL      => $startBase . ($period->{'BaseURL'}->{'content'} // $mpd->{'BaseURL'}->{'content'}),
					segmentTimescale =>$selRepres->{'SegmentTemplate'}->{'timescale'}// $selAdapt->{'SegmentTemplate'}->{'timescale'}// $period->{'SegmentTemplate'}->{'timescale'},
					segmentDuration =>$selRepres->{'SegmentTemplate'}->{'duration'}// $selAdapt->{'SegmentTemplate'}->{'duration'}// $period->{'SegmentTemplate'}->{'duration'},
					segmentURL => $selRepres->{'SegmentTemplate'}->{'media'}// $selAdapt->{'SegmentTemplate'}->{'media'}// $period->{'SegmentTemplate'}->{'media'},
					initializeURL =>$selRepres->{'SegmentTemplate'}->{'initialization'}// $selAdapt->{'SegmentTemplate'}->{'initialization'}// $period->{'SegmentTemplate'}->{'initialization'},
					endNumber    => 0,
					startNumber  => $selAdapt->{'SegmentTemplate'}->{'startNumber'} // 1,
					virtualStartNumber  => $selAdapt->{'SegmentTemplate'}->{'startNumber'} // 1,
					metaEpoch    => 0,
					samplingRate => $selRepres->{'audioSamplingRate'}// $selAdapt->{'audioSamplingRate'},
					channels =>  	$selRepres->{'AudioChannelConfiguration'}->{'value'}// $selAdapt->{'AudioChannelConfiguration'}->{'value'},
					bitrate        => $selRepres->{'bandwidth'},
					duration       => $duration,
					timescale      => $timescale || 1,
					comparisonTime => 0,
					timeShiftDepth => 0,
					mpd            => {
						url      => $dashmpd,
						type     => $mpd->{'type'},
						adaptId  => $selAdapt->{'id'},
						represId => $selRepres->{'id'},
					},
					hideSampleRate => 0,
				};

				#fix urls
				$props->{initializeURL} =~s/\$RepresentationID\$/$selRepres->{id}/;
				$props->{segmentURL} =~s/\$RepresentationID\$/$selRepres->{id}/;

				#hide sample rate if in prefs
				$props->{hideSampleRate} = 1 if $prefs->get('hideSampleRate');

				#force http
				$props->{baseURL} =~s/https:/http:/;

				if ($mpd->{'type'} eq 'dynamic') {
					main::DEBUGLOG && $log->is_debug && $log->debug('dynamic');

					#dynamic
					_getDashUTCTime(
						$mpd->{'UTCTiming'}->{'value'},
						sub {
							my $epochTime = shift;
							$props->{comparisonTime} = Time::HiRes::time();
							main::DEBUGLOG && $log->is_debug && $log->debug('dashtime : ' . $epochTime .  'comparision : ' . $props->{comparisonTime});

							my $index = floor($epochTime / ($props->{segmentDuration} / $props->{segmentTimescale}));
							$props->{startNumber} = $index;
							$props->{virtualStartNumber} = $index;
							$props->{metaEpoch} = $epochTime;
							main::DEBUGLOG && $log->is_debug && $log->debug('Start Number ' . $props->{startNumber});
							$cb->($props);
						},
						sub {
							$log->error('Failed to get dash time ' . $mpd->{'UTCTiming'}->{'value'});
							$cb->();
						}
					);
				} else {

					#static
					$props->{endNumber} = ceil($duration / ($props->{segmentDuration} / $props->{segmentTimescale}));
					$cb->($props);

				}
			},
			onError => sub {
				$log->error("cannot get MPD file $dashmpd");
				$cb->();
			}
		}
	);
}


sub getMetadataFor {
	my ( $class, $client, $full_url ) = @_;
	my $icon = $class->getIcon();

	my ($url) = $full_url =~ /([^&]*)/;
	my $id = $class->getId($url) || return {};
	my $pid = '';
	my $song = $client->playingSong();

	main::DEBUGLOG && $log->is_debug && $log->debug("getmetadata: $url");


	if ( $song && $song->currentTrack()->url eq $full_url ) {

		if (my $meta = $song->pluginData('meta')) {

			# if live, the only place it will be is on the song
			main::DEBUGLOG && $log->is_debug && $log->debug("meta from song");
			$song->track->secs( $meta->{duration} );
			return $meta;
		}
	}


	if ($class->isLive($url)) {

		#leave before we try and attempt to get meta for the PID
		return {
			type  => 'BBCSounds',
			title => $url,
			icon  => 'https://sounds.files.bbci.co.uk/v2/networks/' . _getStationID($url) . '/blocks-colour_600x600.png',
		};
	}


	#aod PID
	$pid = $class->getPid($url);

	main::DEBUGLOG && $log->is_debug && $log->debug("Getting Meta for $id");

	if ( my $meta = $cache->get("bs:meta-$id") ) {
		if ( $song && $song->currentTrack()->url eq $full_url ) {
			my $props = $song->pluginData('props');

			$song->track->secs( $props->{duration});
		}

		main::DEBUGLOG && $log->is_debug && $log->debug('cache hit: ' . $id . ' title: ' . $meta->{'title'});

		return $meta;
	}

	if ( $client->master->pluginData('fetchingBSMeta') ) {
		main::DEBUGLOG
		  && $log->is_debug
		  && $log->debug("already fetching metadata: $id");
		return {
			type  => 'BBCSounds',
			title => $url,
			icon  => $icon,
			cover => $icon,
		};
	}

	# Fetch metadata for Sounds Item


	if (!($class->isLive($url))) {
		$client->master->pluginData( fetchingBSMeta => 1 );
		_getAODMeta(
			$pid,

			#success
			sub {
				my $retMeta = shift;

				$client->master->pluginData( fetchingBSMeta => 0 );
			},

			#failed
			sub {
				my $meta = {
					type  => 'BBCSounds',
					title => $url,
					icon  => $icon,
					cover => $icon,
				};

				$client->master->pluginData( fetchingBSMeta => 0 );
			}
		);

	}
	return {
		type  => 'BBCSounds',
		title => $url,
		icon  => $icon,
		cover => $icon,
	};
}


sub getIcon {
	my ( $class, $url ) = @_;

	return Plugins::BBCSounds::Plugin->_pluginDataFor('icon');
}


sub isLive {
	my ( $class, $url ) = @_;

	my @pid  = split /_/x, $url;
	if ( @pid[1] eq 'LIVE') {
		return 1;
	}else {

		return;
	}
}


sub isRepeatingStream {
	my ( undef, $song ) = @_;

	return isLive(undef, $song->track()->url);
}


sub _getLiveSchedule {
	my $network = shift;
	my $props = shift;
	my $cbY = shift;
	my $cbN = shift;


	main::INFOLOG && $log->is_info && $log->info("Checking Schedule for : $network");


	if (my $schedule = $cache->get("bs:schedule-$network")) {
		main::DEBUGLOG && $log->is_debug && $log->debug("Cache hit for : $network");
		$cbY->($schedule);
	} else {

		Plugins::BBCSounds::BBCSoundsFeeder::getNetworkSchedule(
			$network,
			sub {
				my $scheduleJSON = shift;
				main::DEBUGLOG && $log->is_debug && $log->debug("Fetched schedule for : $network");

				#place in cache for half an hour
				$cache->set("bs:schedule-$network",$scheduleJSON, 1800);
				$cbY->($scheduleJSON);
			},
			sub {

				#place in cache for a couple of hours
				$log->error('Failed to get schedule for ' . $network);

				#try again in 2 mins to prevent flooding
				$cache->set("bs:schedule-$network",{}, 120);
				$cbN->();
			}
		);
	}
}


sub _getIDForBroadcast {
	my $schedule = shift;
	my $offset = shift;
	my $props = shift;

	my $offsetEpoch = floor($offset * ($props->{segmentDuration} / $props->{segmentTimescale}));

	my $items = $schedule->{data};

	main::DEBUGLOG && $log->is_debug && $log->debug("Finding $offset as $offsetEpoch in ");

	for my $item (@$items){
		if (($offsetEpoch >= str2time($item->{start})) && ($offsetEpoch < str2time($item->{end}))) {
			my $id = $item->{id};
			main::DEBUGLOG && $log->is_debug && $log->debug("Found in schedule -  $id  ");
			my $startOffset = floor((str2time($item->{start})-1) / ($props->{segmentDuration} / $props->{segmentTimescale}));
			my $endOffset = floor((str2time($item->{end})-1) / ($props->{segmentDuration} / $props->{segmentTimescale}));

			#take one off it to make sure we end before we begin!

			return {
				id => $id,
				secondsIn => ($offsetEpoch- str2time($item->{start})),
				startOffset => $startOffset,
				endOffset => $endOffset
			};

		}
		main::DEBUGLOG && $log->is_debug && $log->debug('Not found - ' . $item->{start}  . ' - ' . $item->{end});
	}
	$log->warn("No schedule found ");
	return;
}


sub _getAODMeta {
	my $pid = shift;
	my $cbY = shift;
	my $cbN = shift;

	if ( my $meta = $cache->get("bs:meta-$pid") ) {
		main::DEBUGLOG && $log->is_debug && $log->debug("AOD Meta from cache  $pid ");
		$cbY->($meta);
	} else {
		Plugins::BBCSounds::BBCSoundsFeeder::getPidDataForMeta(
			0,$pid,
			sub {
				my $json  = shift;
				my $duration = $json->{'duration'}->{'value'};
				my $title = $json->{'titles'}->{'primary'};
				if ( defined $json->{'titles'}->{'secondary'} ) {
					$title = $title . ' - ' . $json->{'titles'}->{'secondary'};
				}
				if ( defined $json->{'titles'}->{'tertiary'} ) {
					$title = $title . ' ' . $json->{'titles'}->{'tertiary'};
				}
				my $image = $json->{'image_url'};
				$image =~ s/{recipe}/320x320/;
				my $syn = '';
				if ( defined $json->{'synopses'}->{'medium'} ) {
					$syn = $json->{'synopses'}->{'medium'};
				}
				my $meta = {
					title    => $title,
					realTitle => $title,
					artist   => $syn,
					duration => $duration,
					icon     => $image,
					realIcon => $image,
					cover    => $image,
					realCover => $image,
					spotify => '',
					type     => 'BBCSounds',
				};
				$cache->set("bs:meta-$pid",$meta,86400);
				$cbY->($meta);

			},
			sub {
				#cache for 3 minutes so that we don't flood their api
				my $failedmeta ={
					type  => 'BBCSounds',
					title => $pid,
				};
				$cache->set("bs:meta-$pid",$failedmeta,180);
				$cbN->();
			}
		);
	}
	return;
}


sub _getLiveTrack {
	my $network = shift;
	my $currentOffsetTime = shift;
	my $cbY = shift;
	my $cbN = shift;


	if ( my $track = $cache->get("bs:track-$network") ) {
		main::INFOLOG && $log->is_info && $log->info("Live track from cache $network");
		$cbY->($track);
	}else {
		Plugins::BBCSounds::BBCSoundsFeeder::getLatestSegmentForNetwork(
			$network,
			sub {
				my $newTrack=shift;
				if ($newTrack->{total} == 0){

					#no live track on this network/programme at the moment,  let's cache for 3 minutes to give the polling a rest
					$cache->set("bs:track-$network", $newTrack, 180);
					main::INFOLOG && $log->is_info && $log->info("No track available caching status for 3 minutes");
					$cbY->($newTrack);
				}else{
					my $cachetime =  $newTrack->{data}[0]->{offset}->{end} - $currentOffsetTime;
					$cachetime = 240 if $cachetime > 240;  # never cache for more than 4 minutes.
					$cache->set("bs:track-$network", $newTrack, $cachetime) if ($cachetime > 0);
					$newTrack->{total} = 0  if ($cachetime < 0);  #its old, and not playing any more;

					main::INFOLOG && $log->is_info && $log->info("New track title obtained and cached for $cachetime");
					$cbY->($newTrack);
				}
			},
			sub {
				$log->warn('Failed to get track data for '. $network);
				$cbN->();
			}
		);

	}
	return;
}


sub _getAODTrack{

	my $pid = shift;
	my $currentOffsetTime = shift;
	my $cbY = shift;
	my $cbN = shift;

	_getAODTrackData(
		$pid,
		sub {
			my $tracks = shift;
			my $jsonData = $tracks->{data};
			for my $track (@$jsonData) {
				if ($currentOffsetTime >= $track->{offset}->{start}  && $currentOffsetTime < $track->{offset}->{end} ) {
					main::INFOLOG && $log->is_info && $log->info("Identified track in schedule");
					$cbY->({'total' => 1, 'data' => [$track]});
					return;
				}
			}
			main::INFOLOG && $log->is_info && $log->info("No Track available in schedule");

			#nothing found
			$cbY->({'total' => 0});
		},
		$cbN
	);
	return;
}


sub _getAODTrackData {
	my $pid = shift;
	my $cbY = shift;
	my $cbN = shift;


	if ( my $tracks = $cache->get("bs:track-$pid") ) {
		main::INFOLOG && $log->is_info && $log->info("tracks from cache $pid");
		$cbY->($tracks);
	}else {
		Plugins::BBCSounds::BBCSoundsFeeder::getSegmentsForPID(
			$pid,
			sub {
				my $tracks=shift;
				$cache->set("bs:track-$pid", $tracks, 86400);
				main::INFOLOG && $log->is_info && $log->info("Track data obtained for $pid");
				$cbY->($tracks);
			},
			sub {
				$log->warn('Failed to get track data for '. $pid);
				$cbN->();
			}
		);
	}
	return;
}


sub _getLiveMeta {
	my $id = shift;
	my $cbY = shift;
	my $cbN = shift;


	if ( my $meta = $cache->get("bs:meta-$id") ) {
		main::DEBUGLOG && $log->is_debug && $log->debug("Live Meta from cache  $id ");
		$cbY->($meta);
	}else {
		Plugins::BBCSounds::BBCSoundsFeeder::getPidDataForMeta(
			1,$id,
			sub {
				my $ret  = shift;

				my $duration = $ret->{'duration'};
				my $json = $ret->{'programme'};

				my $title = $json->{'titles'}->{'primary'};
				if ( defined $json->{'titles'}->{'secondary'} ) {
					$title = $title . ' - ' . $json->{'titles'}->{'secondary'};
				}
				if ( defined $json->{'titles'}->{'tertiary'} ) {
					$title = $title . ' ' . $json->{'titles'}->{'tertiary'};
				}
				my $image = $json->{'images'}[0]->{url};
				$image =~ s/{recipe}/320x320/;
				my $syn = '';
				if ( defined $json->{'synopses'}->{'medium'} ) {
					$syn = $json->{'synopses'}->{'medium'};
				}
				my $meta = {
					title    => $title,
					realTitle => $title,
					artist   => $syn,
					duration => $duration,
					icon     => $image,
					realIcon => $image,
					cover    => $image,
					realCover    => $image,
					spotify => '',
					type     => 'BBCSounds',
				};

				$cache->set( "bs:meta-" . $id, $meta, 3600 );
				main::DEBUGLOG && $log->is_debug && $log->debug("Live meta receiced and in cache  $id ");
				$cbY->($meta);

			},
			sub {
				$cbN->();
			}
		);
	}
	return;
}


sub _getDashUTCTime {
	my $url  = shift;
	my $cbY  = shift;
	my $cbN  = shift;

	main::DEBUGLOG && $log->is_debug && $log->debug('utc time ' . $url);

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;
			main::DEBUGLOG && $log->is_debug && $log->debug(${ $http->contentRef });
			$cbY->(str2time(${ $http->contentRef }));
		},
		sub {
			$cbN->();
		}
	)->get($url);
}


sub _getLiveMPDUrl {
	my $network  = shift;
	my $cbY  = shift;
	my $cbN  = shift;

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;
			my $json = decode_json ${ $http->contentRef };
			main::DEBUGLOG && $log->is_debug && $log->debug(${ $http->contentRef });

			my $mediaitems = [];
			$mediaitems = $json->{media};
			@$mediaitems = reverse sort { int($a->{bitrate}) <=> int($b->{bitrate}) } @$mediaitems;
			my $mpd = @$mediaitems[0]->{connection}[0]->{href};
			main::INFOLOG && $log->is_info && $log->info("Live MPD $mpd");
			$cbY->($mpd);
			return;
		},
		sub {
			$cbN->();
		}
	)->get("http://open.live.bbc.co.uk/mediaselector/6/select/version/2.0/mediaset/pc/vpid/$network/format/json/");
	return;
}


sub _getStationID {
	my $url  = shift;

	my @stationid  = split /_LIVE_/x, $url;
	return @stationid[1];
}

1;
