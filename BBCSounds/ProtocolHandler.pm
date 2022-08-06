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
use Plugins::BBCSounds::PlayManager;
use Plugins::BBCSounds::Utilities;


use constant MIN_OUT    => 8192;
use constant DATA_CHUNK => 128 * 1024;
use constant PAGE_URL_REGEXP => qr{
    ^ https://www\.bbc\.co\.uk/ (?:
        programmes/ (?<pid> [0-9a-z]+) |
        sounds/play/ (?<pid> live:[_0-9a-z]+ | [0-9a-z]+ )
    ) $
}ix;
use constant CHUNK_TIMEOUT => 4;
use constant CHUNK_RETRYCOUNT => 2;
use constant RESETMETA_THRESHHOLD => 1;

use constant DISPLAYLINE_ALTERNATETRACKWITHPROGRAMME => 1;
use constant DISPLAYLINE_TRACKTITLEWHENPLAYING => 2;
use constant DISPLAYLINE_PROGRAMMEONLY => 3;
use constant DISPLAYLINE_TRACKTITLEONLY => 4;
use constant DISPLAYLINE_PROGRAMMEDESCRIPTION => 5;
use constant DISPLAYLINE_BLANK => 6;

use constant DISPLAYIMAGE_PROGRAMMEIMAGEONLY => 1;
use constant DISPLAYIMAGE_ALTERNATETRACKWITHPROGRAMME => 2;
use constant DISPLAYIMAGE_TRACKIMAGEWHENPLAYING => 3;


my $log   = logger('plugin.bbcsounds');
my $cache = Slim::Utils::Cache->new;
my $prefs = preferences('plugin.bbcsounds');


Slim::Player::ProtocolHandlers->registerHandler( 'sounds', __PACKAGE__ );
Slim::Player::ProtocolHandlers->registerURLHandler(PAGE_URL_REGEXP, __PACKAGE__)
  if Slim::Player::ProtocolHandlers->can('registerURLHandler');

sub flushCache { $cache->cleanup(); }

my $setProperties  = { 'aac' => \&Plugins::BBCSounds::M4a::setProperties };
my $getAudio       = { 'aac' => \&Plugins::BBCSounds::M4a::getAudio };
my $getStartOffset = { 'aac' => \&Plugins::BBCSounds::M4a::getStartOffset };


sub canDoAction {
	my ( $class, $client, $url, $action ) = @_;

	main::INFOLOG && $log->is_info && $log->info("action=$action url=$url");

	if (!( ($class->isLive($url) || $class->isRewind($url)) )) { #an AOD stream
		if ( $action eq 'pause' ) {
			Plugins::BBCSounds::ActivityManagement::heartBeat(Plugins::BBCSounds::ProtocolHandler->getId($url),Plugins::BBCSounds::ProtocolHandler->getPid($url),'paused',floor($client->playingSong()->master->controller->playingSongElapsed));
		}
		if ($action eq 'rew') { #skip back to start of track
			if ( $class->getLastPos($url) > 0) { #if this is a resume at last pos, we want to skip back to the start,not the resume point
				my $song = $client->playingSong();
				my $props = $song->pluginData('props');

				# Set a temporary variable so that the start offset can be ignored if they have skipped back to the start of the track.
				$props->{_ignoreResumePoint} = 1;
				$song->pluginData( props   => $props );
				main::INFOLOG && $log->is_info && $log->info("Allowing skip back to zero on resumed tracks");
				return 1;
			}
		}
	}elsif ($class->isLive($url)) {
		if ($action eq 'stop') { #skip to next track
			 #only allow skiping if we have an end number and it is in the past
			my $song = $client->playingSong();
			my $props = $song->pluginData('props');

			main::INFOLOG && $log->is_info && $log->info('Skipping forward when end number is ' . $props->{endNumber});

			#is the current endNumber in the past?
			if ($props->{endNumber}) {
				if (Time::HiRes::time() > ($class->_timeFromOffset($props->{endNumber},$props)+10)){
					main::INFOLOG && $log->is_info && $log->info('Skip initiated');
					$props->{skip} = 1;
					$song->pluginData( props   => $props );

					return 1;
				}

				main::INFOLOG && $log->is_info && $log->info('Returning to live');

				#force it to reload and therefore return to live
				$props->{isContinue} = 0;
				$song->pluginData( props   => $props );
				return 1;
			}
			return 0; #not ready to know what to do.
		}
		if ($action eq 'rew') { #skip back to start of track
			 # make sure start number is correct for the programme (if we have it)
			my $songTime = Slim::Player::Source::songTime($client);

			my $song = $client->playingSong();
			my $props = $song->pluginData('props');

			if ( ($songTime >= 5) || (!$props->{previousStartNumber}) ) {  # if we are greater than 5 seconds we go back to the start of the current programme
				main::INFOLOG && $log->is_info && $log->info('Rewinding to start of programme');
				$props->{comparisonTime} -= (($props->{startNumber} - $props->{virtualStartNumber})) * ($props->{segmentDuration} / $props->{segmentTimescale});
				$props->{startNumber} = $props->{virtualStartNumber};
			} else { # Go back to the previous programme

				main::INFOLOG && $log->is_info && $log->info('Rewinding to previous programme');
				$props->{comparisonTime}    -= (($props->{startNumber} - $props->{previousStartNumber})) * ($props->{segmentDuration} / $props->{segmentTimescale});
				$props->{startNumber}        = $props->{previousStartNumber};
				$props->{virtualStartNumber} = $props->{previousStartNumber};
				$props->{previousStartNumber} = 0;
				$props->{endNumber} = 0;
			}

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

	my $nowPlayingButtons = $prefs->get('nowPlayingActivityButtons');
	$song->pluginData( nowPlayingButtons => $nowPlayingButtons );

	main::INFOLOG && $log->is_info && $log->info("Proposed Seek $startTime  -  offset $seekdata->{'timeOffset'}  NowPlayingButtons $nowPlayingButtons ");

	if ($startTime) {

		if ($class->isLive($masterUrl) || $class->isRewind($masterUrl)) {

			#we can't go into the future
			my $edge = $class->_calculateEdgeFromTime(Time::HiRes::time(),$props);
			my $maxStartTime = $edge - ($props->{virtualStartNumber} * ($props->{segmentDuration} / $props->{segmentTimescale}));

			#Remove a chunk to provide safety margin and less wait time on restart
			$maxStartTime -= ($props->{segmentDuration} / $props->{segmentTimescale});

			$startTime = $maxStartTime if ($startTime > $maxStartTime);

			main::INFOLOG && $log->is_info && $log->info("Seeking to $startTime  edge $edge  maximum start time $maxStartTime");

			#This "song" has a maximum age
			my $maximumAge = 18000;  # 5 hours
			if ((Time::HiRes::time() - $props->{comparisonTime}) > $maximumAge) {

				#we need to end this track and let it rise again
				$log->error('Live stream to old after pause, stopping the continuation.');
				$props->{isContinue} = 0;
				$song->pluginData( props   => $props );
				return;
			}
		}else {
			if ($props->{_ignoreResumePoint}) {

				# we have skipped back when there is a resume point. clear it and set start time to zero
				$startTime = 0;
				$props->{_ignoreResumePoint} = 0;
				$song->pluginData( props   => $props );
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

	#Throttle setup
	my $throttleInterval = $prefs->get('throttleInterval');
	my $nextThrottle = time();

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
			'session' 	  => Slim::Networking::Async::HTTP->new,
			'baseURL'	  => $args->{'url'},
			'resetMeta'=> 1,
			'retryCount' => 0,  #Counting Chunk retries
			'liveId'   => '',  # The ID of the live programme playing
			'firstIn'  => 1,   # An indicator for the first data call
			'trackData' => {   # For managing showing live track data
				'chunkCounter' => 0,   # for managing showing show title or track in a 4/2 regime
				'isShowingTitle' => 1,   # indicates what cycle we are on
				'awaitingCb' => 0,      #flag for callback on track data
				'trackPlaying' => 0,  #flag indicating meta data is showing track is playing
				'pollTime' => 30,    #Track polling default every 30 seconds
				'lastPoll' => $nextThrottle  #last time we polled
			},
			'nextHeartbeat' =>  time() + 30,  #AOD data sends a heartbeat to the BBC
			'throttleInterval' => $throttleInterval,   #A value to delay making streaming data available to help the community firmware
			'nextThrottle' => $nextThrottle,
		};
	}

	# set starting offset (bytes or index) if not defined yet
	$getStartOffset->{ $props->{'format'} }(
		$args->{url},
		$startTime,
		$props,
		sub {
			${*$self}{'vars'}->{offset} = shift;
			$log->info( "starting from offset " .  ${*$self}{'vars'}->{offset} );
		}
	) if !defined $offset;

	# set timer for updating the MPD if needed (dash)
	${*$self}{'active'} = 1;    #SM Removed timer


	return $self;
}


sub close {
	my $self = shift;

	${*$self}{'active'} = 0;
	${*$self}{'vars'}->{'session'}->disconnect;

	main::INFOLOG && $log->is_info && $log->info('close called');


	my $props    = ${*$self}{'props'};

	if ($props->{isDynamic}) {
		my $song      = ${*$self}{'song'};
		my $v        = $self->vars;

		#make sure we don't try and continue if we were streaming when it is started again.
		if ($v->{streaming} && (!$props->{skip})) {
			$props->{isContinue} = 0;
			$song->pluginData( props   => $props );
			main::INFOLOG && $log->info("Ensuring live stream closed");
		} elsif ( $props->{skip} ) {
			main::INFOLOG && $log->info("Force next track");
			$props->{isContinue} = 1;
			$song->pluginData( props   => $props );
		}

	}


	$self->SUPER::close(@_);
}


sub onStop {
	my ( $class, $song ) = @_;
	my $elapsed = $song->master->controller->playingSongElapsed;
	my $id = Plugins::BBCSounds::ProtocolHandler->getId( $song->track->url );


	if	(!( ($class->isLive( $song->track->url ) || $class->isRewind( $song->track->url )) )) {
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
	if (!( ($class->isLive($url) || $class->isRewind($url)) )) {
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


sub audioScrobblerSource {

	# R (radio source)
	return 'R';
}


sub getSeekData {
	my ( $class, $client, $song, $newtime ) = @_;

	main::INFOLOG && $log->info( 'Trying to seek ' . $newtime . ' seconds for offset ' . $song->track->audio_offset );

	return { timeOffset => $newtime };
}


sub vars {
	return ${ *{ $_[0] } }{'vars'};
}

my $nextWarning = 0;


sub _getPlayingImage {
	my $self = shift;
	my $programmeImage = shift;
	my $trackImage = shift;
	my $v = $self->vars;

	my $imagePref = $prefs->get('displayimage');

	return $programmeImage if $imagePref == DISPLAYIMAGE_PROGRAMMEIMAGEONLY;

	if ($imagePref == DISPLAYIMAGE_ALTERNATETRACKWITHPROGRAMME) {
		return $trackImage if ($trackImage ne '') && $v->{'trackData'}->{trackPlaying} == 1 && $v->{'trackData'}->{isShowingTitle} == 1;
		return $programmeImage;
	}

	if ($imagePref == DISPLAYIMAGE_TRACKIMAGEWHENPLAYING ) {
		return $trackImage if ($trackImage ne '') && $v->{'trackData'}->{trackPlaying} == 1;
		return $programmeImage;
	}

	#how did we get here?
	$log->error('Could not return display image');
	return;
}


sub _getPlayingDisplayLine {
	my $self = shift;
	my $line = shift;
	my $programme = shift;
	my $track = shift;
	my $description = shift;
	my $v = $self->vars;

	my $displaytype = 0;
	$displaytype = $prefs->get('displayline1') if $line == 1;
	$displaytype = $prefs->get('displayline2') if $line == 2;
	$displaytype = $prefs->get('displayline3') if $line == 3;


	main::DEBUGLOG && $log->is_debug && $log->debug("Prefs for line $line is $displaytype input $track | $programme | $description");

	return '' 			if $displaytype == DISPLAYLINE_BLANK;
	return $track		if $displaytype == DISPLAYLINE_TRACKTITLEONLY;
	return $programme   if $displaytype == DISPLAYLINE_PROGRAMMEONLY;
	return $description if $displaytype == DISPLAYLINE_PROGRAMMEDESCRIPTION;

	if ($displaytype == DISPLAYLINE_ALTERNATETRACKWITHPROGRAMME) {
		return $track 	if $v->{'trackData'}->{trackPlaying} == 1 && $v->{'trackData'}->{isShowingTitle} == 1;
		return $programme;
	}

	if ($displaytype == DISPLAYLINE_TRACKTITLEWHENPLAYING) {
		return $track	if $v->{'trackData'}->{trackPlaying} == 1;
		return $programme;
	}

	#how did we get here?
	$log->error('Could not return display line ' . $line);
	return;
}


sub liveTrackData {
	my $self = shift;
	my $currentOffset = shift;
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
	$v->{'trackData'}->{awaitingCb} = 1;

	if ($v->{'trackData'}->{isShowingTitle}) {

		#we only need to reset the title if we have gone forward 3
		if ($v->{'trackData'}->{chunkCounter} < 4) {
			$v->{'trackData'}->{awaitingCb} = 0;
			return;
		}

		$v->{'trackData'}->{isShowingTitle} = 0;
		$v->{'trackData'}->{chunkCounter} = 1;


		my $meta = $song->pluginData('meta');
		my $oldmeta;
		%$oldmeta = %$meta;
		$meta->{title} = $self->_getPlayingDisplayLine(1, $meta->{realTitle}, $meta->{track}, $meta->{description});
		$meta->{artist} = $self->_getPlayingDisplayLine(2, $meta->{realTitle}, $meta->{track}, $meta->{description});
		$meta->{album} = $self->_getPlayingDisplayLine(3, $meta->{realTitle}, $meta->{track}, $meta->{description});
		$meta->{icon} = $self->_getPlayingImage($meta->{realIcon}, $meta->{trackImage});
		$meta->{cover} = $self->_getPlayingImage($meta->{realCover}, $meta->{trackImage});

		if ( _isMetaDiff($meta, $oldmeta) ) {

			my $cb = sub {
				main::INFOLOG && $log->is_info && $log->info("Setting title back after callback");
				$song->pluginData( meta  => $meta );
				Slim::Music::Info::setCurrentTitle( $masterUrl, $meta->{title}, $client );
				Slim::Control::Request::notifyFromArray( $client, ['newmetadata'] );
				$v->{'trackData'}->{awaitingCb} = 0;
			};

			#the title will be set when the current buffer is done
			Slim::Music::Info::setDelayedCallback( $client, $cb );
		} else {
			$v->{'trackData'}->{awaitingCb} = 0;
		}


	} else {

		#we only need to set the title if we have gone forward 3 chunks
		if ($v->{'trackData'}->{chunkCounter} < 4) {
			$v->{'trackData'}->{awaitingCb} = 0;
			return;
		}
		$v->{'trackData'}->{isShowingTitle} = 1;
		$v->{'trackData'}->{chunkCounter} = 1;


		my $props =  ${*$self}{'props'};

		my $sub;
		my $isLive;

		if ($self->isLive($masterUrl) || $self->isRewind($masterUrl)) {
			$sub = sub {
				my $cbY = shift;
				my $cbN = shift;
				_getLiveTrack(_getStationID($masterUrl), $self->_timeFromOffset( $currentOffset, $props) - $self->_timeFromOffset($props->{virtualStartNumber},$props),$cbY,$cbN);
				$v->{'trackData'}->{lastPoll} = time();
			};
			$isLive = 1;
		} else {
			$sub = sub {
				my $cbY = shift;
				my $cbN = shift;
				_getAODTrack($self->getId($masterUrl), $self->_timeFromOffset( $currentOffset, $props),$cbY,$cbN);
				$v->{'trackData'}->{lastPoll} = time();
			};
			$isLive = 0;
		}

		if ( $isLive && ((time() < ($v->{'trackData'}->{lastPoll} + $v->{'trackData'}->{pollTime})) || ($v->{'trackData'}->{pollTime} == 0)) ) {
			$v->{'trackData'}->{awaitingCb} = 0;
			return;
		}

		$sub->(
			sub {
				my $track = shift;
				my $meta = $song->pluginData('meta');
				my $oldmeta;
				%$oldmeta = %$meta;

				if ($track->{total} == 0) {

					#nothing there
					$v->{'trackData'}->{trackPlaying} = 0;
					$meta->{track} = '';

					$meta->{title} = $self->_getPlayingDisplayLine(1, $meta->{realTitle}, $meta->{track}, $meta->{description});
					$meta->{artist} = $self->_getPlayingDisplayLine(2, $meta->{realTitle}, $meta->{track}, $meta->{description});
					$meta->{album} = $self->_getPlayingDisplayLine(3, $meta->{realTitle}, $meta->{track}, $meta->{description});
					$meta->{icon} = $self->_getPlayingImage($meta->{realIcon}, $meta->{trackImage});
					$meta->{cover} = $self->_getPlayingImage($meta->{realCover}, $meta->{trackImage});
					$meta->{spotify} = '';

					if ( _isMetaDiff($meta, $oldmeta) ) {

						my $cb = sub {
							main::INFOLOG && $log->is_info && $log->info("Setting new live title after callback");
							$song->pluginData( meta  => $meta );
							Slim::Music::Info::setCurrentTitle( $masterUrl, $meta->{title}, $client );
							Slim::Control::Request::notifyFromArray( $client, ['newmetadata'] );
							$v->{'trackData'}->{awaitingCb} = 0;
						};

						#the title will be set when the current buffer is done
						Slim::Music::Info::setDelayedCallback( $client, $cb );

					} else {
						$v->{'trackData'}->{awaitingCb} = 0;
					}

					return;
				} else {

					if (($self->isLive($masterUrl) || $self->isRewind($masterUrl)) && (($self->_timeFromOffset($props->{virtualStartNumber},$props) + $track->{data}[0]->{offset}->{start}) > $self->_timeFromOffset( $currentOffset, $props))) {

						main::INFOLOG && $log->is_info && $log->info("Have new title but not playing yet");

						$v->{'trackData'}->{trackPlaying} = 0;
						$meta->{track} = '';


						$meta->{title} = $self->_getPlayingDisplayLine(1, $meta->{realTitle}, $meta->{track}, $meta->{description});
						$meta->{artist} = $self->_getPlayingDisplayLine(2, $meta->{realTitle}, $meta->{track}, $meta->{description});
						$meta->{album} = $self->_getPlayingDisplayLine(3, $meta->{realTitle}, $meta->{track}, $meta->{description});
						$meta->{icon} =	 $self->_getPlayingImage($meta->{realIcon}, $meta->{trackImage});
						$meta->{cover} = $self->_getPlayingImage($meta->{realCover}, $meta->{trackImage});
						$meta->{spotify} = '';

						if ( _isMetaDiff($meta, $oldmeta) ) {

							my $cb = sub {
								main::INFOLOG && $log->is_info && $log->info("Setting new live title after callback");
								$song->pluginData( meta  => $meta );
								Slim::Music::Info::setCurrentTitle( $masterUrl, $meta->{title}, $client );
								Slim::Control::Request::notifyFromArray( $client, ['newmetadata'] );
								$v->{'trackData'}->{awaitingCb} = 0;
							};

							#the title will be set when the current buffer is done
							Slim::Music::Info::setDelayedCallback( $client, $cb );

						} else {
							$v->{'trackData'}->{awaitingCb} = 0;
						}

						return;
					}

					$meta->{track} = $track->{data}[0]->{titles}->{secondary} . ' by ' . $track->{data}[0]->{titles}->{primary};
					$v->{'trackData'}->{trackPlaying} = 1;

					$meta->{title} = $self->_getPlayingDisplayLine(1, $meta->{realTitle}, $meta->{track}, $meta->{description});
					$meta->{artist} = $self->_getPlayingDisplayLine(2, $meta->{realTitle}, $meta->{track}, $meta->{description});
					$meta->{album} = $self->_getPlayingDisplayLine(3, $meta->{realTitle}, $meta->{track}, $meta->{description});

					if ( my $image = $track->{data}[0]->{image_url} ) {
						$image =~ s/{recipe}/320x320/;
						$meta->{trackImage} = $image;
						$meta->{icon} = $self->_getPlayingImage($meta->{realIcon}, $meta->{trackImage});
						$meta->{cover} = $self->_getPlayingImage($meta->{realCover}, $meta->{trackImage});
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

					if ( _isMetaDiff($meta, $oldmeta) ) {


						main::INFOLOG && $log->is_info && $log->info("Setting new live title $meta->{track}");
						my $cb = sub {
							main::INFOLOG && $log->is_info && $log->info("Setting new live title after callback");
							$song->pluginData( meta  => $meta );
							Slim::Music::Info::setCurrentTitle( $masterUrl, $meta->{title}, $client );
							Slim::Control::Request::notifyFromArray( $client, ['newmetadata'] );
							$v->{'trackData'}->{awaitingCb} = 0;
						};

						#the title will be set when the current buffer is done
						Slim::Music::Info::setDelayedCallback( $client, $cb );
					} else {
						$v->{'trackData'}->{awaitingCb} = 0;
					}

				}
			},
			sub {
				# an error occured
				$v->{'trackData'}->{isShowingTitle} = 1;
				$v->{'trackData'}->{awaitingCb} = 0;
				$v->{'trackData'}->{trackPlaying} = 0;

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

			# the AOD meta is more accurate
			my $props = ${*$self}{'props'};
			$retMeta->{'duration'} = $props->{'duration'};

			if ( my $meta = $song->pluginData('meta') ) {  #Ensure the type is propagated through
				$retMeta->{type} = $meta->{type};
			}
			$song->pluginData( meta  => $retMeta );
			Slim::Music::Info::setCurrentTitle( $masterUrl, $retMeta->{title}, $client );
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
	my $isLive = shift;
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

						#Ensure that it is known that we have rewound live
						if ((!$isLive) && $prefs->get('rewoundind')) {
							$retMeta->{title} = '<Rewound> ' . $retMeta->{title};
						}

						if ( my $meta = $song->pluginData('meta') ) {  #Ensure the type is propagated through
							$retMeta->{type} = $meta->{type};
						}

						$song->pluginData( meta  => $retMeta );

						#fix progress bar
						$client->playingSong()->can('startOffset')
						  ? $client->playingSong()->startOffset($resp->{secondsIn})
						  : ( $client->playingSong()->{startOffset} = $resp->{secondsIn} );
						$client->master()->remoteStreamStartTime( Time::HiRes::time() - $resp->{secondsIn} );
						$client->playingSong()->duration( $retMeta->{duration} );
						$song->track->secs( $retMeta->{duration} );

						#we can now set the end point for this
						$v->{'endOffset'} = $resp->{endOffset};
						$v->{'resetMeta'} = 0;

						#update in the props
						my $props      = ${*$self}{'props'};
						$props->{endNumber} = $resp->{endOffset};
						$props->{virtualStartNumber} = $resp->{startOffset};

						#ensure plug in data up to date
						$song->pluginData( props   => $props );

						Slim::Music::Info::setCurrentTitle( $masterUrl, $retMeta->{title}, $client );
						Slim::Music::Info::setDelayedCallback( $client, sub { Slim::Control::Request::notifyFromArray( $client, ['newmetadata'] ); }, 'output-only' );

						main::INFOLOG && $log->is_info && $log->info('Set Offsets '  . $props->{'virtualStartNumber'} . ' ' . $v->{'endOffset'} . ' for '. $id);


						#Ensure polling is set up correctly
						Plugins::BBCSounds::BBCSoundsFeeder::getNetworkTrackPollingInfo(
							$station,
							sub {
								my $poll = shift;
								if ($poll) {
									$v->{'trackData'}->{'pollTime'} = $poll;
								} else {
									$v->{'trackData'}->{'pollTime'} = 0; # never poll
								}
								main::INFOLOG && $log->is_info && $log->info("Track Polling set to " . $v->{'trackData'}->{'pollTime'});
							},
							sub {
								#Failed to get poll time, set it to zero
								$v->{'trackData'}->{'pollTime'} = 0;
								$log->warn("Failed polling setting to  " . $v->{'trackData'}->{'pollTime'});
							}
						);

						#Finally, get the previous start number, if there is one and we haven't got one already
						if ( !($props->{previousStartNumber}) ) {							
							if (my $lastresp = _getIDForBroadcast($schedule, $props->{virtualStartNumber} - 1, $props ) ) {

								$props->{previousStartNumber} = $lastresp->{startOffset};
								$song->pluginData( props   => $props );
							}
						}

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
		},
		! $isLive
	);
}


sub explodePlaylist {
	my ( $class, $client, $uri, $cb ) = @_;

	if ( $uri =~ PAGE_URL_REGEXP ) {
		my $pid = $+{'pid'};
		if ( $pid =~ m/^live:(.+)$/ ) {
			my $stationid = $1;
			$cb->(["sounds://_LIVE_$stationid"]);
		}else {
			$log->debug("Fetching soundsurl for $pid to get vpid");
			Plugins::BBCSounds::PlayManager::getSoundsURLForPid(
				$pid,
				sub {
					my $url = shift;
					$cb->([$url]);
				},
				sub {
					$log->error("Failed to get sounds url for $pid");
					$cb->([]);
				}
			);
		}
	}else {

		$cb->([$uri]);
	}

	return;
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
		&& $v->{'streaming'}) {
		my $url =  $v->{'baseURL'};
		my $bail = 0;
		if ($props->{isDynamic}) {
			main::INFOLOG && $log->is_info && $log->info('Need More data, we have ' . length $v->{'outBuf'} . ' in the buffer');

			#check if we can get more if not leave
			my $edge = $self->_calculateEdge($v->{'offset'}, $props);
			main::DEBUGLOG && $log->is_debug && $log->debug('Edge = ' . $edge . ' Now : '. Time::HiRes::time() . ' First In : ' .$v->{'firstIn'});
			if ((!$v->{'firstIn'} ) && $edge > Time::HiRes::time()) {

				main::INFOLOG && $log->is_info && $log->info('Data not yet available for '  . $v->{'offset'} . ' now ' . Time::HiRes::time() . ' edge ' . $edge );
				$bail = 1;
			}
		}

		main::DEBUGLOG && $log->is_debug && $log->debug('Throttle '  . $v->{'nextThrottle'} . ' now ' . time());
		if ( (!$bail) && ($v->{'nextThrottle'} > time()) ) {
			main::INFOLOG && $log->is_info && $log->info('Throttle bail');
			$bail = 1;
		}


		if (!$bail) {
			$v->{'firstIn'} = 0;
			main::INFOLOG && $log->is_info && $log->info("Fetching " . $v->{'offset'} . ' towards the end of '. $v->{'endOffset'} . 'base url :' . $url);
			my $headers = [ 'Connection', 'keep-alive' ];
			my $suffix;

			$suffix = $props->{'segmentURL'};
			my $replOffset = ( $v->{'offset'} );
			$suffix =~ s/\$Number\$/$replOffset/;
			$url .= $suffix;

			$v->{'offset'}++;


			my $request = HTTP::Request->new( GET => $url, $headers);
			$request->protocol('HTTP/1.1');

			$v->{'fetching'} = 1;

			$v->{'session'}->send_request(
				{
					request => $request,
					onBody => sub {
						my $response = shift->response;

						#A Throttle to help with community firmware buffering problem.
						$v->{'nextThrottle'} += $v->{'throttleInterval'};
						main::DEBUGLOG && $log->is_debug && $log->debug('Next Throttle  will be : ' . $v->{'nextThrottle'} . ' Time Now  : ' . time());

						$v->{'inBuf'} .= $response->content;
						$v->{'fetching'} = 0;
						$v->{'retryCount'} = 0;

						if (($v->{'endOffset'} > 0) && ($v->{'offset'} > $v->{'endOffset'})) {
							$v->{'streaming'} = 0;
							if ($props->{'isDynamic'}) {
								$props->{'isContinue'} = 1;
								$song->pluginData( props   => $props );
								main::INFOLOG && $log->is_info && $log->info('Dynamic track has ended and stream will continue');
							}
						}

						main::DEBUGLOG && $log->is_debug && $log->debug("got chunk $v->{'offset'} length: ",length $response->content," for $url");


						if ($props->{'isDynamic'}) {

							my $edge = $self->_calculateEdge($v->{'offset'}, $props);
							my $isNow = (Time::HiRes::time()-$edge) < 30;

							# get the meta data for this live track if we don't have it yet.

							$self->liveMetaData($isNow) if ($v->{'endOffset'} == 0  || $v->{'resetMeta'} >= RESETMETA_THRESHHOLD);

							# check for live track if we are within striking distance of the live edge
							$self->liveTrackData($replOffset) if $isNow;

						} else {
							$self->aodMetaData() if ($v->{'resetMeta'} >= RESETMETA_THRESHHOLD);
							$self->liveTrackData($replOffset);
						}

						#increment until we reach the threshold to ensure we give the player enough playing data before taking up time getting meta data
						$v->{'resetMeta'}++ if $v->{'resetMeta'} > 0;
					},

					onError => sub {

						$v->{'retryCount'}++;

						if ($v->{'retryCount'} > CHUNK_RETRYCOUNT) {

							$log->error("Failed to get $url");
							$v->{'inBuf'}    = '';
							$v->{'fetching'} = 0;
							$v->{'streaming'} = 0
							  if ($v->{'endOffset'} > 0) && ($v->{'offset'} > $v->{'endOffset'});
						} else {
							$log->warn("Retrying of $url");
							$v->{'offset'}--;  # try the same offset again
							$v->{'fetching'} = 0;
						}
					},
					Timeout => CHUNK_TIMEOUT,
				}
			);
		}
	}

	# process all available data
	$getAudio->{ $props->{'format'} }( $v, $props ) if length $v->{'inBuf'};

	if (my $bytes = min( length $v->{'outBuf'}, $maxBytes ) ) {
		main::DEBUGLOG && $log->is_debug && $log->debug('Bytes . ' . $maxBytes . ' . ' . length $v->{'outBuf'});
		$_[1] = substr( $v->{'outBuf'}, 0, $bytes, '' );

		return $bytes;
	} elsif ( $v->{'streaming'} || $props->{'updatePeriod'} ) {
		main::DEBUGLOG && $log->is_debug && $log->debug('No bytes available' . Time::HiRes::time());

		#bbc heartbeat at a quiet time.
		if (!($self->isLive($masterUrl) || $self->isRewind($masterUrl))) {
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

	if (!($class->isLive($url) || $class->isRewind($url))) {
		my @pid = split /_/x, $url;
		if ((scalar @pid) == 4) {
			$lastpos = @pid[3];
		}
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
		push @allowDASH,([ 'audio_1=96000', 'aac', 96_000 ],[ 'audio_1=48000', 'aac', 48_000 ]);
		@allowDASH = sort { @$a[2] < @$b[2] } @allowDASH;

		my $dashmpd = $url;
		my $overrideEpoch;

		$overrideEpoch = getRewindEpoch($masterUrl) if $class->isRewind($masterUrl);

		getMPD(
			$dashmpd,
			\@allowDASH,
			sub {
				my $props = shift;
				return $errorCb->() unless $props;
				$song->pluginData( props   => $props );
				$song->pluginData( baseURL => $props->{'baseURL'} );
				$setProperties->{ $props->{'format'} }( $song, $props, $successCb );
			},
			$overrideEpoch
		);
	};


	if ($class->isLive($masterUrl) || $class->isRewind($masterUrl)) {

		my $stationid = _getStationID($masterUrl);


		#if we already have props then this is a continuation
		if (my $existingProps = $song->pluginData('props')) {
			if ( $existingProps->{isContinue} && $existingProps->{isDynamic} ) {
				return $errorCb->() unless ($existingProps->{endNumber} > 0);
				$existingProps->{comparisonTime} += (($existingProps->{endNumber} - $existingProps->{startNumber}) + 1) * ($existingProps->{segmentDuration} / $existingProps->{segmentTimescale});
				$existingProps->{previousStartNumber} = $existingProps->{virtualStartNumber};
				$existingProps->{startNumber} = $existingProps->{endNumber} + 1;
				$existingProps->{virtualStartNumber} = $existingProps->{startNumber};
				$existingProps->{endNumber} = 0;
				$existingProps->{skip} = 0;
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
				title => $stationid,
				icon  => $class->getIcon(),
			}
		);

		_getMPDUrl(
			$stationid,
			sub {
				$url = shift;
				$processMPD->();
			},
			sub {
				$log->error('Failed to get live MPD');
				$errorCb->("Not able to obtain live audio", $masterUrl);
			}
		);


	}else{

		my $id = $class->getId($masterUrl);

		$song->pluginData(
			meta => {
				title => $id,
				icon  => $class->getIcon(),
			}
		);

		_getMPDUrl(
			$id,
			sub {
				$url = shift;
				$processMPD->();
			},
			sub {
				$log->error('Failed to get Audio information.  It may not be available in your location.');
				$errorCb->("Not able to obtain audio", $masterUrl);
			}
		);

	}
}


sub getMPD {
	my ( $dashmpd, $allow, $cb, $overrideEpoch ) = @_;

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

				main::INFOLOG
				  && $log->is_info
				  && $log->info('source base : ' . $res->base);

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
					$startBase = $endURI->scheme . '://' . $endURI->host . dirname( $endURI->path ) . '/';
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
					isContinue =>   1,
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

				if ($mpd->{'type'} eq 'dynamic') {
					main::DEBUGLOG && $log->is_debug && $log->debug('dynamic -  base url ' .  $props->{baseURL});

					#dynamic
					_getDashUTCTime(
						$mpd->{'UTCTiming'}->{'value'},
						sub {
							my $epochTime = shift;
							$props->{comparisonTime} = Time::HiRes::time();

							# If we are on a previous (live) rewind programme we need to adjust
							if (defined $overrideEpoch) {
								$props->{comparisonTime} = $props->{comparisonTime} - ($epochTime - $overrideEpoch);
								$epochTime = $overrideEpoch;
							}

							$props->{metaEpoch} = $epochTime;

							main::DEBUGLOG && $log->is_debug && $log->debug('dashtime : ' . $epochTime .  'comparision : ' . $props->{comparisonTime} . ' Segment duration : ' . $props->{segmentDuration} . ' Segment timescale : ' . $props->{segmentTimescale} );

							my $index = floor($epochTime / ($props->{segmentDuration} / $props->{segmentTimescale}));
							$props->{startNumber} = $index;
							$props->{virtualStartNumber} = $index;

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

			if (!($class->isLive($url) || $class->isRewind($url))) {
				$song->track->secs( $meta->{duration} );
			}

			if ($song->pluginData('nowPlayingButtons')) {
				if ($meta->{containerUrn} ne '') {

					$meta->{buttons} = {

						repeat  => {
							icon    => Plugins::BBCSounds::Utilities::IMG_NOWPLAYING_BOOKMARK,
							jiveStyle => 'thumbsUp',
							tooltip => 'Bookmark the episode',
							command => [ 'sounds', 'bookmark', $meta->{urn},materialIcon => 'add' ]
						},

						shuffle => {
							icon    =>  Plugins::BBCSounds::Utilities::IMG_NOWPLAYING_SUBSCRIBE,
							jiveStyle => 'love',
							tooltip => 'Subscribe to series',
							command => [ 'sounds', 'subscribe', $meta->{containerUrn}  ],
						},
					};
				} else {
					$meta->{buttons} = {

						repeat  => {
							icon    => Plugins::BBCSounds::Utilities::IMG_NOWPLAYING_BOOKMARK,
							jiveStyle => 'thumbsUp',
							tooltip => 'Bookmark the episode',
							command => [ 'sounds', 'bookmark', $meta->{urn} ],
						},
					};
				}
			}
			return $meta;
		}
	}


	if ($class->isLive($url) || $class->isRewind($url)) {

		#leave before we try and attempt to get meta for the PID
		return {
			title => $url,
			icon  => 'https://sounds.files.bbci.co.uk/v2/networks/' . _getStationID($url) . '/blocks-colour_600x600.png',
		};
	}


	#aod PID
	$pid = $class->getPid($url);

	main::DEBUGLOG && $log->is_debug && $log->debug("Getting Meta for $id");

	if ( my $meta = $cache->get("bs:meta-$pid") ) {
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
			title => $url,
			icon  => $icon,
			cover => $icon,
		};
	}

	# Fetch metadata for Sounds Item


	if (!($class->isLive($url) || $class->isRewind($url))) {
		$client->master->pluginData( fetchingBSMeta => 1 );
		_getAODMeta(
			$pid,

			#success
			sub {
				my $retMeta = shift;
				$client->master->pluginData( fetchingBSMeta => 0 );
				$client->currentPlaylistUpdateTime( Time::HiRes::time() );
				Slim::Control::Request::notifyFromArray( $client, ['newmetadata'] );
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


sub isRewind {
	my ( $class, $url ) = @_;

	my @pid  = split /_/x, $url;
	if ( @pid[1] eq 'REWIND') {
		return 1;
	}else {

		return;
	}
}


sub isContainer {
	my ( $class, $url ) = @_;

	my @pid  = split /_/x, $url;
	if ( @pid[1] eq 'CONTAINER') {
		return 1;
	}else {

		return;
	}
}


sub getRewindEpoch {
	my $url  = shift;

	my @ep  = split /_/x, $url;
	return @ep[2];

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
	my $isRewind = shift;

	main::INFOLOG && $log->is_info && $log->info("Checking Schedule for : $network");

	if (my $schedule = $cache->get("bs:schedule-$isRewind-$network")) {
		main::DEBUGLOG && $log->is_debug && $log->debug("Cache hit for : $isRewind-$network");
		$cbY->($schedule);
	} else {

		Plugins::BBCSounds::BBCSoundsFeeder::getNetworkSchedule(
			$network,
			sub {
				my $scheduleJSON = shift;
				main::DEBUGLOG && $log->is_debug && $log->debug("Fetched schedule for : $isRewind-$network");

				#cache only if rewound
				$cache->set("bs:schedule-$isRewind-$network",$scheduleJSON, 120) if $isRewind;
				$cbY->($scheduleJSON);
			},
			sub {
				
				$log->error('Failed to get schedule for ' . $network);

				#try again in 2 mins to prevent flooding
				$cache->set("bs:schedule-$isRewind-$network",{}, 120);
				$cbN->();
			},
			$isRewind
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
			$id = $item->{pid} if !(defined $id); #sometimes it is the pid not the id.  I think this is an inconsistency in the API for previous broadcasts
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
	main::INFOLOG && $log->is_info && $log->info("No Schedule Found");
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
				my $urn = $json->{'urn'};

				my $containerUrn = '';
				if (defined $json->{'container'}->{'urn'}) {
					$containerUrn = $json->{'container'}->{'urn'};
				}

				my $meta = {
					title    => $title,
					realTitle => $title,
					artist   => $syn,
					description => $syn,
					duration => $duration,
					icon     => $image,
					realIcon => $image,
					cover    => $image,
					realCover => $image,
					trackImage => '',
					track => '',
					spotify => '',
					buttons => undef,
					urn => $urn,
					containerUrn => $containerUrn
				};
				$cache->set("bs:meta-$pid",$meta,86400);
				$cbY->($meta);

			},
			sub {
				#cache for 3 minutes so that we don't flood their api
				my $failedmeta ={title => $pid,};
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

					#no live track on this network/programme at the moment

					main::INFOLOG && $log->is_info && $log->info("No track available");
					$cbY->($newTrack);
				}else{
					my $cachetime =  $newTrack->{data}[0]->{offset}->{end} - $currentOffsetTime;
					$cachetime = 240 if $cachetime > 240;  # never cache for more than 4 minutes.

					$cache->set("bs:track-$network", $newTrack, $cachetime) if ($cachetime > 0);
					$newTrack->{total} = 0  if ($newTrack->{data}[0]->{offset}->{now_playing} == 0);  #for some reason it is set to not playing

					main::INFOLOG && $log->is_info && $log->info("New track title obtained and cached for $cachetime Now Playing : " . $newTrack->{data}[0]->{offset}->{now_playing});
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
				my $urn = $json->{'urn'};

				my $meta = {
					title    => $title,
					realTitle => $title,
					artist   => $syn,
					description => $syn,
					duration => $duration,
					icon     => $image,
					realIcon => $image,
					cover    => $image,
					realCover    => $image,
					trackImage => '',
					track =>   '',
					spotify => '',
					buttons => undef,
					urn => $urn,
					containerUrn => '',
				};

				$cache->set( "bs:meta-" . $id, $meta, 3600 );
				main::DEBUGLOG && $log->is_debug && $log->debug("Live meta received and in cache  $id ");
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


sub _getMPDUrl {
	my $id  = shift;
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

			# find the first that is dash
			my $connections = @$mediaitems[0]->{connection};
			my $protocol = 'https';
			$protocol = 'http' if $prefs->get('forceHTTP');
			for my $connection (@$connections) {
				if ($connection->{transferFormat} eq 'dash' && $connection->{protocol} eq $protocol){
					my $mpd = $connection->{href};
					main::INFOLOG && $log->is_info && $log->info("MPD $mpd");
					$cbY->($mpd);
					return;
				}
			}

			#fallback to http if appropriate
			if ($prefs->get('forceHTTP') ne 'on') {
				$log->warn("Falling back to http as no https found");
				$protocol = 'http';
				for my $connection (@$connections) {
					if ($connection->{transferFormat} eq 'dash' && $connection->{protocol} eq $protocol){
						my $mpd = $connection->{href};
						main::INFOLOG && $log->is_info && $log->info("MPD $mpd");
						$cbY->($mpd);
						return;
					}
				}
			}

			$log->error("No Dash Found");
			$cbN->();
		},
		sub {
			$cbN->();
		}
	)->get("https://open.live.bbc.co.uk/mediaselector/6/select/version/2.0/mediaset/pc/vpid/$id/format/json/");
	return;
}


sub _getStationID {
	my $url  = shift;

	my @stationid  = split /_LIVE_/x, $url;
	return @stationid[1];
}


sub _isMetaDiff {
	my $meta1 = shift;
	my $meta2 = shift;

	if (   ($meta1->{title} eq $meta2->{title})
		&& ($meta1->{artist} eq $meta2->{artist})
		&& ($meta1->{album} eq $meta2->{album})
		&& ($meta1->{cover} eq $meta2->{cover})
		&& ($meta1->{track} eq $meta2->{track})) {

		return;

	} else {

		main::INFOLOG && $log->is_info && $log->info("Meta Data Changed");
		return 1;
	}
}

1;
