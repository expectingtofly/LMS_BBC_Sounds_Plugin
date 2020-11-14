package Plugins::BBCSounds::ProtocolHandler;

#  stu@expectingtofly.co.uk and philippe_44@outlook.com
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

use constant MIN_OUT    => 8192;
use constant DATA_CHUNK => 128 * 1024;

my $log   = logger('plugin.bbcsounds');
my $cache = Slim::Utils::Cache->new;

my $nextHeartbeat = 0;

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

	main::DEBUGLOG && $log->is_debug && $log->debug( Dumper($props) );

	# erase last position from cache
	$cache->remove( "bs:lastpos-" . $class->getId($masterUrl) );

	$args->{'url'} = $song->pluginData('baseURL');

	my $seekdata =$song->can('seekdata') ? $song->seekdata : $song->{'seekdata'};
	my $startTime = $seekdata->{'timeOffset'} || $class->getLastPos($masterUrl);
	$song->pluginData( 'lastpos', 0 );

	if ($startTime) {
		$song->can('startOffset')
		  ? $song->startOffset($startTime)
		  : ( $song->{startOffset} = $startTime );
		$args->{'client'}->master->remoteStreamStartTime( Time::HiRes::time() - $startTime );
		$offset = undef;
	}

	main::INFOLOG
	  && $log->is_info
	  && $log->info( "url: $args->{url} master: $masterUrl offset: ",$startTime || 0 );

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

	# for live stream, always set duration to timeshift depth
	#SM not supporting live stream
	$song->pluginData( 'liveStream', 0 );

	return $self;
}


sub close {
	my $self = shift;

	${*$self}{'active'} = 0;

	main::INFOLOG && $log->is_info && $log->info('close called');

	$self->SUPER::close(@_);
}


sub onStop {
	my ( $class, $song ) = @_;
	my $elapsed = $song->master->controller->playingSongElapsed;
	my $id = Plugins::BBCSounds::ProtocolHandler->getId( $song->track->url );

	Plugins::BBCSounds::ActivityManagement::heartBeat( $id,Plugins::BBCSounds::ProtocolHandler->getPid( $song->track->url ),'paused', floor($elapsed) );

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

	$nextHeartbeat = time() + 30;

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

	return { timeOffset => $newtime };
}


sub vars {
	return ${ *{ $_[0] } }{'vars'};
}

my $nextWarning = 0;


sub sysread {
	use bytes;

	my $self = $_[0];

	# return in $_[1]
	my $maxBytes = $_[2];
	my $v        = $self->vars;
	my $baseURL  = ${*$self}{'url'};
	my $props    = ${*$self}{'props'};

	# means waiting for offset to be set
	if ( !defined $v->{offset} ) {
		$! = EINTR;
		return undef;
	}


	# need more data
	if (   length $v->{'outBuf'} < MIN_OUT
		&& !$v->{'fetching'}
		&& $v->{'streaming'} ){
		my $url = $baseURL;
		my @range;
		if ($props->{isDynamic}) {

			#check if we can get more if not leave
			my $edge = ((($v->{'offset'} - $props->{startNumber}) * ($props->{segmentDuration} / $props->{segmentTimescale})) + $props->{comparisonTime});
			main::DEBUGLOG && $log->is_debug && $log->debug('Edge = ' . $edge . ' Now : '. time());
			if ($edge > time()){

				#bail
				main::DEBUGLOG && $log->is_debug && $log->debug('bailing');
				$! = EINTR;
				return undef;
			}
		}


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
				  if $v->{'offset'} == $props->{'endNumber'};
				main::DEBUGLOG && $log->is_debug && $log->debug("got chunk $v->{'offset'} length: ",length $_[0]->content," for $url");

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
			},

		)->get( $url, @range );
	}

	# process all available data
	$getAudio->{ $props->{'format'} }( $v, $props ) if length $v->{'inBuf'};

	if ( my $bytes = min( length $v->{'outBuf'}, $maxBytes ) ) {
		$_[1] = substr( $v->{'outBuf'}, 0, $bytes );
		$v->{'outBuf'} = substr( $v->{'outBuf'}, $bytes );
		return $bytes;
	}elsif ( $v->{'streaming'} || $props->{'updatePeriod'} ) {

		#bbc heartbeat at a quiet time.
		if ( time() > $nextHeartbeat ) {
			my $song      = ${*$self}{'song'};
			my $masterUrl = $song->track()->url;
			if (!($self->isLive($masterUrl))) {
				Plugins::BBCSounds::ActivityManagement::heartBeat(Plugins::BBCSounds::ProtocolHandler->getId($masterUrl),Plugins::BBCSounds::ProtocolHandler->getPid($masterUrl),'heartbeat',floor( $song->master->controller->playingSongElapsed ));
			}
			$nextHeartbeat = time() + 30;
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

	$song->pluginData( lastpos => ( $masterUrl =~ /&lastpos=([\d]+)/ )[0]|| 0 );
	$masterUrl =~ s/&.*//;

	my $url ='';
	if ($class->isLive($masterUrl)) {
		my $stationid = $class->getStationID($masterUrl);
		$url ='http://a.files.bbci.co.uk/media/live/manifesto/audio/simulcast/dash/uk/dash_full/llnws/' . $stationid . '.mpd';

	}else{
		my $id = $class->getId($masterUrl);
		$url ='http://open.live.bbc.co.uk/mediaselector/6/redir/version/2.0/mediaset/audio-syndication-dash/proto/http/vpid/'. $id;
	}

	my @allowDASH = ();

	main::INFOLOG
	  && $log->is_info
	  && $log->info("url: $url master: $masterUrl");

	push @allowDASH,([ 'audio_eng=320000',  'aac', 320_000 ],[ 'audio=320000',  'aac', 320_000 ],[ 'audio_eng=128000',  'aac', 128_000 ],[ 'audio=128000',  'aac', 128_000 ],[ 'audio_eng_1=96000', 'aac', 96_000 ],[ 'audio=96000', 'aac', 96_000 ],[ 'audio_eng_1=48000', 'aac', 48_000 ],[ 'audio=48000', 'aac', 48_000 ]);
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
}


sub getMPD {
	my ( $dashmpd, $allow, $cb ) = @_;

	my $session = Slim::Networking::Async::HTTP->new;
	my $mpdrequest = HTTP::Request->new( GET => $dashmpd );

	main::INFOLOG
	  && $log->is_info
	  && $log->info("In Get MPD");
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
				  && $log->info("have mpd");


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


				main::INFOLOG
				  && $log->is_info
				  && $log->info(Dumper($mpd));


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

				my $duration = $mpd->{'mediaPresentationDuration'};
				my ( $misc, $hour, $min, $sec ) = $duration =~/P(?:([^T]*))T(?:(\d+)H)?(?:(\d+)M)?(?:([+-]?([0-9]*[.])?[0-9]+)S)?/;
				$duration =( $sec || 0 ) +( ( $min  || 0 ) * 60 ) +( ( $hour || 0 ) * 3600 );

				my $scaleDuration	= $selAdapt->{'SegmentTemplate'}->{'duration'};
				my $timescale 		= $selAdapt->{'SegmentTemplate'}->{'timescale'};
				$duration = $scaleDuration / $timescale if $scaleDuration;


				main::INFOLOG
				  && $log->is_info
				  && $log->info("MPD duration $duration");

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
					startNumber  => $selAdapt->{'SegmentTemplate'}->{'startNumber'} // 0,
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
				};

				#fix urls
				$props->{initializeURL} =~s/\$RepresentationID\$/$selRepres->{id}/;
				$props->{segmentURL} =~s/\$RepresentationID\$/$selRepres->{id}/;

				#force http
				$props->{baseURL} =~s/https:/http:/;

				if ($mpd->{'type'} eq 'dynamic') {
					main::DEBUGLOG && $log->is_debug && $log->debug('dynamic');

					#dynamic
					_getDashUTCTime(
						$mpd->{'UTCTiming'}->{'value'},
						sub {
							my $epochTime = shift;
							$props->{comparisonTime} = time();
							main::DEBUGLOG && $log->is_debug && $log->debug('dashtime : ' . $epochTime .  'comparision : ' . $props->{comparisonTime});

							my $index = floor($epochTime / ($props->{segmentDuration} / $props->{segmentTimescale}));
							$props->{startNumber} = $index + $props->{startNumber} - 1;
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
	my $pid = $class->getPid($url);

	main::DEBUGLOG && $log->is_debug && $log->debug("getmetadata: $url");

	if ( my $meta = $cache->get("bs:meta-$id") ) {
		my $song = $client->playingSong();

		if ( $song && $song->currentTrack()->url eq $full_url ) {
			$song->track->secs( $meta->{duration} );
		}

		main::DEBUGLOG && $log->is_debug && $log->debug("cache hit: $id");

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
	if (!($class->isLive($url))) {


		# Fetch metadata for Sounds Item

		$client->master->pluginData( fetchingBSMeta => 1 );

		Plugins::BBCSounds::BBCSoundsFeeder::getPidDataForMeta(
			$pid,
			sub {
				my $json  = shift;
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
					artist   => $syn,
					duration => $json->{'duration'}->{'value'},
					icon     => $image,
					cover    => $image,
					type     => 'BBCSounds',
				};

				$cache->set( "bs:meta-" . $id, $meta, 86400 );
				$client->master->pluginData( fetchingBSMeta => 0 );
			},
			sub {
				my $meta = {
					type  => 'BBCSounds',
					title => $url,
					icon  => $icon,
					cover => $icon,
				};

				#an error occurred lets just cache the default menu for 5 mins then it will try later so we don't flood
				$cache->set( "bs:meta-" . $id, $meta, 300 );
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


sub getStationID {
	my ( $class, $url ) = @_;

	my @stationid  = split /_LIVE_/x, $url;
	return @stationid[1];
}

1;
