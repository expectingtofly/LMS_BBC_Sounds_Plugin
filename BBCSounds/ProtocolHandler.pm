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
use POSIX qw(floor ceil);

use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Errno;
use Slim::Utils::Cache;

use Plugins::BBCSounds::M4a;
use Plugins::BBCSounds::BBCSoundsFeeder;
use Plugins::BBCSounds::PlayManager;
use Plugins::BBCSounds::Utilities;
use Plugins::BBCSounds::SessionManagement;


use constant MIN_OUT    => 8192;
use constant DATA_CHUNK => 128 * 1024;
use constant PAGE_URL_REGEXP => qr{
    ^ https://www\.bbc\.co\.uk/ (?:
        programmes/ (?<pid> [0-9a-z]+) |
        sounds/play/ (?<pid> live:[_0-9a-z]+ | [0-9a-z]+ )
    ) $
}ix;
use constant CHUNK_TIMEOUT => 5;
use constant CHUNK_RETRYCOUNT => 2;
use constant CHUNK_FAILURECOUNT => 5;
use constant RESETMETA_THRESHHOLD => 1;
use constant PROGRAMME_LATENCY => 38.4;

use constant DISPLAYLINE_TRACKBYARTIST => 1;
use constant DISPLAYLINE_TRACK => 2;
use constant DISPLAYLINE_ARTIST => 3;
use constant DISPLAYLINE_PROGRAMMETITLE => 10;
use constant DISPLAYLINE_PROGRAMMEDESCRIPTION => 11;
use constant DISPLAYLINE_STATIONNAME => 12;
use constant DISPLAYLINE_BLANK => 13;

use constant DISPLAYIMAGE_TRACKIMAGE => 1;
use constant DISPLAYIMAGE_PROGRAMMEIMAGE => 2;

use constant REWOUND_IND => '<Rewound> ';


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
			Plugins::BBCSounds::ActivityManagement::heartBeat( getId($url), getPid($url) ,'paused',floor($client->playingSong()->master->controller->playingSongElapsed));
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
			 #only allow skipping if we have an end number and it is in the past
			my $song = $client->playingSong();
			my $props = $song->pluginData('props');

			if ( $props->{reverseSkip} ) {
				main::INFOLOG && $log->is_info && $log->info('Skipping back');
				$props->{skip} = 1;
				$props->{isContinue} = 0;
				$song->pluginData( props   => $props );
				return 1;
			}

			main::INFOLOG && $log->is_info && $log->info('Skipping forward when end number is ' . $props->{endNumber});

			#is the current endNumber in the past?
			if ($props->{endNumber}) {
				if (Time::HiRes::time() > (_timeFromOffset($props->{endNumber},$props)+10)){
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
			my $songTime = Slim::Player::Source::songTime($client);

			my $song = $client->playingSong();
			my $props = $song->pluginData('props');
			main::INFOLOG && $log->is_info && $log->info('Rewind Pressed song time : ' . $songTime);

			if ( ($songTime >= 8) || (!$props->{previousStartNumber}) ) {  # if we are greater than 5 seconds we go back to the start of the current programme
				main::INFOLOG && $log->is_info && $log->info('Rewinding to start of programme');
				$props->{comparisonTime} -= (($props->{comparisonStartNumber} - $props->{startNumber})) * ($props->{segmentDuration} / $props->{segmentTimescale});
				$props->{comparisonStartNumber} = $props->{startNumber};
				$song->pluginData( props   => $props );

			} else { # Go back to the previous programme
				main::INFOLOG && $log->is_info && $log->info('Rewinding to previous programme');
				
				$props->{reverseSkip} = 1;
				$song->pluginData( props   => $props );
				# Trigger the ski after the callback
				Slim::Utils::Timers::setTimer(
					undef,
					time(),
					sub {
						$client->controller()->skip();
				} );
			}
			return 1;
		}
		if ( $action eq 'pause' ) {
			my $song = $client->playingSong();
			my $meta = $song->pluginData('meta');
			$meta->{pausePoint} = time();
			$song->pluginData( meta   => $meta );
			main::INFOLOG && $log->is_info && $log->info('Setting pause point to ' . $meta->{pausePoint});
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
	my $meta = $song->pluginData('meta');

	my $liveEdge = 1;

	my $masterUrl = $song->track()->url;

	return undef if !defined $props;

	$args->{'url'} = $song->pluginData('baseURL');

	my $seekdata =$song->can('seekdata') ? $song->seekdata : $song->{'seekdata'};
	my $startTime = $seekdata->{'timeOffset'} || $class->getLastPos($masterUrl);

	my $nowPlayingButtons = $prefs->get('nowPlayingActivityButtons');
	$song->pluginData( nowPlayingButtons => $nowPlayingButtons );

	if ($meta->{pausePoint}) {
		$meta->{pausePoint} = 0;
		$song->pluginData( meta   => $meta );
		main::DEBUGLOG && $log->is_debug && $log->debug('Pause point set to zero');
	}

	main::INFOLOG && $log->is_info && $log->info("Proposed Seek $startTime  -  offset $seekdata->{'timeOffset'}  NowPlayingButtons $nowPlayingButtons ");

	if ($class->isLive($masterUrl) || $class->isRewind($masterUrl)) {

		#we can't go into the future
		my $edge = $class->_calculateEdgeFromTime(Time::HiRes::time(),$props);
		my $maxStartTime = $edge - ($props->{startNumber} * ($props->{segmentDuration} / $props->{segmentTimescale}));

		#Remove a chunk to provide safety margin and less wait time on restart
		$maxStartTime -= ($props->{segmentDuration} / $props->{segmentTimescale});

		$startTime = $maxStartTime if $startTime && ($startTime > $maxStartTime);

		$liveEdge =  $maxStartTime - $startTime if ($maxStartTime > $startTime);
		
		main::INFOLOG && $log->is_info && $log->info("Seeking to $startTime  edge $edge live_edge $liveEdge maximum start time $maxStartTime");

		#This "song" has a maximum age
		my $maximumAge = 18000;  # 5 hours
		if ((Time::HiRes::time() - $props->{comparisonTime}) > $maximumAge) {

			#we need to end this track and let it rise again
			$log->error('Live stream too old after pause, stopping the continuation.');
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

	
	main::INFOLOG
	  && $log->is_info
	  && $log->info( "url: $args->{url} master: $masterUrl offset: ",$startTime|| 0 );

	my $self = $class->SUPER::new;

	#prefs setup
	my $throttleInterval = $prefs->get('throttleInterval');
	my $programmeimagePref = $prefs->get('programmedisplayimage');
	my $trackimagePref = $prefs->get('trackdisplayimage');
	my $programmedisplayline1 = $prefs->get('programmedisplayline1');
	my $programmedisplayline2 = $prefs->get('programmedisplayline2');
	my $programmedisplayline3 = $prefs->get('programmedisplayline3');
	my $trackdisplayline1 = $prefs->get('trackdisplayline1');
	my $trackdisplayline2 = $prefs->get('trackdisplayline2');
	my $trackdisplayline3 = $prefs->get('trackdisplayline3');
	my $rewoundInd = $prefs->get('rewoundind');
	my $noBlankTrackImage = $prefs->get('noBlankTrackImage');
	
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
			'failureCount' => 0,  #Counting Chunk failures
			'liveId'   => '',  # The ID of the live programme playing
			'firstIn'  => 1,   # An indicator for the first data call
			'trackData' => {   # For managing showing live track data
				'chunkCounter' => 0,   # for managing showing show title or track in a 4/2 regime
				'isShowingTitle' => 1,   # indicates what cycle we are on
				'awaitingCb' => 0,      #flag for callback on track data
				'trackPlaying' => 0,  #flag indicating meta data is showing track is playing
				'pollTime' => 1,    #Track polling default every 30 seconds
				'lastPoll' => $nextThrottle  #last time we polled
			},
			'nextHeartbeat' =>  time() + 30,  #AOD data sends a heartbeat to the BBC
			'throttleInterval' => $throttleInterval,   #A value to delay making streaming data available to help the community firmware
			'nextThrottle' => $nextThrottle,
			'edge'		=> $liveEdge,
			'displayPrefs' => {
				'programmeDisplayLine1' => $programmedisplayline1,
				'programmeDisplayLine2' => $programmedisplayline2,
				'programmeDisplayLine3' => $programmedisplayline3,
				'trackDisplayLine1' => $trackdisplayline1,
				'trackDisplayLine2' => $trackdisplayline2,
				'trackDisplayLine3' => $trackdisplayline3,
				'programmeImagePref' => $programmeimagePref,
				'trackImagePref' => $trackimagePref,
				'rewoundInd' => $rewoundInd,
				'noBlankTrackImage' => $noBlankTrackImage,
			}
		};
	}
	

	# set starting offset (bytes or index) if not defined yet
	$getStartOffset->{ $props->{'format'} }(
		$args->{url},
		$startTime,
		$props,
		sub {
			${*$self}{'vars'}->{offset} = shift;
			main::INFOLOG && $log->is_info && $log->info( "starting from offset " .  ${*$self}{'vars'}->{offset} );			
			if ($startTime) {
				my $realStart = (${*$self}{'vars'}->{offset} - $props->{startNumber}) * ($props->{segmentDuration} / $props->{segmentTimescale});
			
				$song->can('startOffset')
			  	? $song->startOffset($realStart)
			  	: ( $song->{startOffset} = $realStart );

				my $remote = Time::HiRes::time() - $realStart;
				main::INFOLOG && $log->is_info && $log->info( "Remote Stream Start Time =  $remote  Proposed start time $startTime Real start time $realStart ");
				$args->{'client'}->master->remoteStreamStartTime($remote);
			}
		}
	) if !defined $offset;

	return $self;
}


sub close {
	my $self = shift;

	${*$self}{'vars'}->{'session'}->disconnect;

	main::INFOLOG && $log->is_info && $log->info('close called');


	my $props    = ${*$self}{'props'};

	if ($props->{isDynamic}) {
		my $song      = ${*$self}{'song'};
		my $v        = $self->vars;

		#make sure we don't try and continue if we were streaming when it is started again.
		if ($v->{streaming} && (!( $props->{skip} || $props->{reverseSkip}))) {
			$props->{isContinue} = 0;
			$song->pluginData( props   => $props );
			main::INFOLOG && $log->info("Ensuring live stream closed");
		} elsif ( $props->{skip} || $props->{reverseSkip} ) {
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

	if	(!( ($class->isLive( $song->track->url ) || $class->isRewind( $song->track->url )) )) {
		my $id = getId( $song->track->url );
		my $pid = getPid( $song->track->url );
		Plugins::BBCSounds::ActivityManagement::heartBeat( $id, $pid,'paused', floor($elapsed) );
	}

}


sub onStream {
	my ( $class, $client, $song ) = @_;
	my $url  = $song->track->url;		

	#perform starting heartbeat
	if (!( ($class->isLive($url) || $class->isRewind($url)) )) {
		my $id   = getId($url);
		my $id = getId( $song->track->url );
		my $pid = getPid( $song->track->url );
		Plugins::BBCSounds::ActivityManagement::heartBeat($id, $pid,'started', floor( $song->master->controller->playingSongElapsed ));
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

	if ($v->{'trackData'}->{trackPlaying} == 1) {
		return $trackImage if  length($trackImage) && $v->{'displayPrefs'}->{'trackImagePref'} == DISPLAYIMAGE_TRACKIMAGE  
								&& ((!$v->{'displayPrefs'}->{'noBlankTrackImage'}) || ($v->{'displayPrefs'}->{'noBlankTrackImage'} && $trackImage !~ /p0bqcdzf/));
		return $programmeImage;
	} else {
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
	my $artist = shift;
	my $description = shift;
	my $station =shift;
	my $v = $self->vars;

	my $programmedisplaytype = 0;
	my $trackdisplaytype = 0;
	$programmedisplaytype =  $v->{'displayPrefs'}->{'programmeDisplayLine'. $line};
	$trackdisplaytype = $v->{'displayPrefs'}->{'trackDisplayLine'. $line};


	main::DEBUGLOG && $log->is_debug && $log->debug("Prefs for line $line is $programmedisplaytype & $trackdisplaytype input $track | $programme | $artist | $description | $station|");

	if ($v->{'trackData'}->{trackPlaying} == 1) {
		main::DEBUGLOG && $log->is_debug && $log->debug("Return display for track");
		return $track . ' by ' . $artist if $trackdisplaytype == DISPLAYLINE_TRACKBYARTIST;
		return $track if $trackdisplaytype == DISPLAYLINE_TRACK;
		return $artist if $trackdisplaytype == DISPLAYLINE_ARTIST;
		return $programme if $trackdisplaytype == DISPLAYLINE_PROGRAMMETITLE;
		return $description if $trackdisplaytype == DISPLAYLINE_PROGRAMMEDESCRIPTION;
		return $station if $trackdisplaytype == DISPLAYLINE_STATIONNAME;
		return '';
	} else {
		main::DEBUGLOG && $log->is_debug && $log->debug("Return display for programme");
		return $programme if $programmedisplaytype == DISPLAYLINE_PROGRAMMETITLE;
		return $description if $programmedisplaytype == DISPLAYLINE_PROGRAMMEDESCRIPTION;
		return $station if $programmedisplaytype == DISPLAYLINE_STATIONNAME;
		return '';
	}

	$log->error('Could not return display line ' . $line);
	return;
}


sub liveTrackData {
	my $self = shift;
	my $currentOffset = shift;
	my $isNow = shift;
	my $firstIn = shift;

	my $client = ${*$self}{'client'};
	my $v = $self->vars;

	my $song  = ${*$self}{'song'};
	my $masterUrl = $song->track()->url;
	my $station = _getStationID($masterUrl);

	my $isUrlLive = $self->isLive($masterUrl);
	my $isUrlRewind = $self->isRewind($masterUrl);

	$v->{'trackData'}->{chunkCounter}++;

	# we must leave if we have a title waiting to be changed by buffer callback
	return if $v->{'trackData'}->{awaitingCb};
	$v->{'trackData'}->{awaitingCb} = 1;

	if ($v->{'trackData'}->{isShowingTitle} || !$isNow ) {

		#we only need to reset the title if we have gone forward 3
		if (!$firstIn && $v->{'trackData'}->{chunkCounter} < 4) {
			$v->{'trackData'}->{awaitingCb} = 0;
			return;
		}

		$v->{'trackData'}->{isShowingTitle} = 0;
		$v->{'trackData'}->{chunkCounter} = 1;


		my $meta = $song->pluginData('meta');
		my $oldmeta;
		%$oldmeta = %$meta;

		my $titlePrefix = '';
		if ((!$isNow) && $v->{displayPrefs}->{rewoundInd} ) {
			$titlePrefix = REWOUND_IND;
			main::INFOLOG && $log->is_info && $log->info('Setting rewound indicator');
		}
		$meta->{title} = $titlePrefix . $self->_getPlayingDisplayLine(1, $meta->{realTitle}, $meta->{track}, $meta->{artist}, $meta->{description}, $meta->{station});
		$meta->{artist} = $self->_getPlayingDisplayLine(2, $meta->{realTitle}, $meta->{track}, $meta->{artist}, $meta->{description}, $meta->{station});
		$meta->{album} = $self->_getPlayingDisplayLine(3, $meta->{realTitle}, $meta->{track}, $meta->{artist}, $meta->{description}, $meta->{station});
		$meta->{icon} = $self->_getPlayingImage($meta->{realIcon}, $meta->{trackImage});
		$meta->{cover} = $self->_getPlayingImage($meta->{realCover}, $meta->{trackImage});
		$meta->{live_edge} = $v->{'edge'} if $isUrlLive;

		if ( _isMetaDiff($meta, $oldmeta, $isUrlLive) ) {

			my $cb = sub {
				main::INFOLOG && $log->is_info && $log->info("Setting title back after callback");
				$song->pluginData( meta  => $meta );
				Slim::Music::Info::setCurrentTitle( $masterUrl, $meta->{title}, $client );
				Slim::Control::Request::notifyFromArray( $client, ['newmetadata'] );
				$v->{'trackData'}->{awaitingCb} = 0;
			};

			#the title will be set when the current buffer is done
			if ( $firstIn ) {
				main::INFOLOG && $log->is_info && $log->info("Setting meta immediatly");
				$cb->();
			} else {
				Slim::Music::Info::setDelayedCallback( $client, $cb );
			}
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

		if ( $isUrlLive || $isUrlRewind ) {
			if ( $v->{'trackData'}->{'pollTime'} == 1 ) {
				$v->{'trackData'}->{awaitingCb} = 1;
				#Ensure polling is set up correctly
				Plugins::BBCSounds::BBCSoundsFeeder::getNetworkTrackPollingInfo(
					_getStationID($masterUrl),
					sub {
						my $poll = shift;
						if ($poll) {
							$v->{'trackData'}->{'pollTime'} = $poll;
						} else {
							$v->{'trackData'}->{'pollTime'} = 0; # never poll
						}
						main::INFOLOG && $log->is_info && $log->info("Track Polling set to " . $v->{'trackData'}->{'pollTime'});
						$v->{'trackData'}->{awaitingCb} = 0;
					},
					sub {
						#Failed to get poll time, set it to zero
						$v->{'trackData'}->{'pollTime'} = 0;
						$log->warn("Failed polling setting to  " . $v->{'trackData'}->{'pollTime'});
						$v->{'trackData'}->{awaitingCb} = 0;
					}
				);
				return;
			}

			$sub = sub {
				my $cbY = shift;
				my $cbN = shift;
				_getLiveTrack(_getStationID($masterUrl), _timeFromOffset( $currentOffset, $props) - _timeFromOffset($props->{startNumber},$props),$cbY,$cbN);
				$v->{'trackData'}->{lastPoll} = time();
			};

			$isLive = 1;
		} else {
			$sub = sub {
				my $cbY = shift;
				my $cbN = shift;
				_getAODTrack(getId($masterUrl), _timeFromOffset( $currentOffset, $props),$cbY,$cbN);
				$v->{'trackData'}->{lastPoll} = time();
			};
			$isLive = 0;
		}


		if ( $isLive && ((time() < ($v->{'trackData'}->{lastPoll} + $v->{'trackData'}->{pollTime})) || ($v->{'trackData'}->{pollTime} < 2)) ) {
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
					$meta->{artist} = '';

					$meta->{title} = $self->_getPlayingDisplayLine(1, $meta->{realTitle}, $meta->{track}, $meta->{artist}, $meta->{description}, $meta->{station});
					$meta->{artist} = $self->_getPlayingDisplayLine(2, $meta->{realTitle}, $meta->{track}, $meta->{artist}, $meta->{description}, $meta->{station});
					$meta->{album} = $self->_getPlayingDisplayLine(3, $meta->{realTitle}, $meta->{track}, $meta->{artist}, $meta->{description}, $meta->{station});
					$meta->{icon} = $self->_getPlayingImage($meta->{realIcon}, $meta->{trackImage});
					$meta->{cover} = $self->_getPlayingImage($meta->{realCover}, $meta->{trackImage});
					$meta->{spotify} = '';

					if ( _isMetaDiff($meta, $oldmeta, $isUrlLive) ) {

						my $cb = sub {
							main::INFOLOG && $log->is_info && $log->info("Setting new live title after callback");
							
							my $currentMeta = $song->pluginData('meta');							
							if ( $currentMeta->{urn} eq $meta->{urn} ) {
								#only update if the meta has been updated by the next track
								$song->pluginData( meta  => $meta );
								Slim::Music::Info::setCurrentTitle( $masterUrl, $meta->{title}, $client );
								Slim::Control::Request::notifyFromArray( $client, ['newmetadata'] );
							}
							$v->{'trackData'}->{awaitingCb} = 0;
						};

						#the title will be set when the current buffer is done
						Slim::Music::Info::setDelayedCallback( $client, $cb );

					} else {
						$v->{'trackData'}->{awaitingCb} = 0;
					}

					return;
				} else {

					if (($isUrlLive || $isUrlRewind) && ((_timeFromOffset($props->{startNumber},$props) + $track->{data}[0]->{offset}->{start}) > _timeFromOffset( $currentOffset, $props))) {

						main::INFOLOG && $log->is_info && $log->info("Have new title but not playing yet");

						$v->{'trackData'}->{trackPlaying} = 0;
						$meta->{track} = '';
						$meta->{artist} = '';

						$meta->{title} = $self->_getPlayingDisplayLine(1, $meta->{realTitle}, $meta->{track}, $meta->{artist}, $meta->{description}, $meta->{station});
						$meta->{artist} = $self->_getPlayingDisplayLine(2, $meta->{realTitle}, $meta->{track}, $meta->{artist}, $meta->{description}, $meta->{station});
						$meta->{album} = $self->_getPlayingDisplayLine(3, $meta->{realTitle}, $meta->{track}, $meta->{artist}, $meta->{description}, $meta->{station});
						$meta->{icon} =	 $self->_getPlayingImage($meta->{realIcon}, $meta->{trackImage});
						$meta->{cover} = $self->_getPlayingImage($meta->{realCover}, $meta->{trackImage});
						$meta->{spotify} = '';

						if ( _isMetaDiff($meta, $oldmeta, $isUrlLive) ) {

							my $cb = sub {

								my $currentMeta = $song->pluginData('meta');								
								if ( $currentMeta->{urn} eq $meta->{urn} ) {
									main::INFOLOG && $log->is_info && $log->info("Setting new live title after callback");
									$song->pluginData( meta  => $meta );
									Slim::Music::Info::setCurrentTitle( $masterUrl, $meta->{title}, $client );
									Slim::Control::Request::notifyFromArray( $client, ['newmetadata'] );
								}
								$v->{'trackData'}->{awaitingCb} = 0;
							};

							#the title will be set when the current buffer is done
							Slim::Music::Info::setDelayedCallback( $client, $cb );

						} else {
							$v->{'trackData'}->{awaitingCb} = 0;
						}

						return;
					}

					$meta->{track} = $track->{data}[0]->{titles}->{secondary};
					$meta->{artist} = $track->{data}[0]->{titles}->{primary};
					$v->{'trackData'}->{trackPlaying} = 1;

					$meta->{title} = $self->_getPlayingDisplayLine(1, $meta->{realTitle}, $meta->{track}, $meta->{artist},  $meta->{description}, $meta->{station});
					$meta->{artist} = $self->_getPlayingDisplayLine(2, $meta->{realTitle}, $meta->{track}, $meta->{artist}, $meta->{description}, $meta->{station});
					$meta->{album} = $self->_getPlayingDisplayLine(3, $meta->{realTitle}, $meta->{track}, $meta->{artist}, $meta->{description}, $meta->{station});

					if ( my $image = $track->{data}[0]->{image_url} ) {
						$image =~ s/{recipe}/320x320/;
						$meta->{trackImage} = $image;
						$meta->{icon} = $self->_getPlayingImage($meta->{realIcon}, $meta->{trackImage});
						$meta->{cover} = $self->_getPlayingImage($meta->{realCover}, $meta->{trackImage});
					} else {
						$meta->{trackImage} = '';
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

					if ( _isMetaDiff($meta, $oldmeta, $isUrlLive) ) {


						main::INFOLOG && $log->is_info && $log->info("Setting new live title $meta->{track}");
						my $cb = sub {
							main::INFOLOG && $log->is_info && $log->info("Setting new live title after callback");

							my $currentMeta = $song->pluginData('meta');							
							if ( $currentMeta->{urn} eq $meta->{urn} ) {
								$song->pluginData( meta  => $meta );
								Slim::Music::Info::setCurrentTitle( $masterUrl, $meta->{title}, $client );
								Slim::Control::Request::notifyFromArray( $client, ['newmetadata'] );
							}
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

	my ( $class, $currentOffset, $props) = @_;

	my $seglength = ($props->{segmentDuration} / $props->{segmentTimescale});
	my $edge = ($currentOffset - $props->{comparisonStartNumber}) * $seglength;
	$edge += ($props->{comparisonTime} - $seglength);

	return $edge;
}


sub _timeFromOffset {
	my ($currentOffset, $props) = @_;
	my $seglength = ($props->{segmentDuration} / $props->{segmentTimescale});
	return ($currentOffset * $seglength);
}


sub _calculateEdgeFromTime {
	my ( $class, $currentTime, $props) = @_;	

	my $seglength = ($props->{segmentDuration} / $props->{segmentTimescale});
	my $currentOffset = $currentTime / $seglength;
	my $edge = ($currentOffset - $props->{comparisonStartNumber}) * $seglength;
	$edge += $props->{comparisonTime};

	return $edge;

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
			
			if ( $edge > Time::HiRes::time() ) {

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

						#check if we have all the data, if not retry
						my $respLength = $response->headers->{'content-length'};

						if ( $respLength != length($response->content) ) {
							$v->{'retryCount'}++;

							$log->warn("Audio chunk did not match expected response, retrying...");

							if ($v->{'retryCount'} > CHUNK_RETRYCOUNT) {

								$log->error("Failed to get $url");
								$v->{'failureCount'}++;
								$v->{'inBuf'}    = '';
								$v->{'fetching'} = 0;
								$v->{'streaming'} = 0
								  if ((($v->{'endOffset'} > 0) && ($v->{'offset'} > $v->{'endOffset'})) || $v->{'failureCount'} > CHUNK_FAILURECOUNT );
							} else {
								$log->warn("Retrying of $url");
								$v->{'offset'}--;  # try the same offset again
								$v->{'fetching'} = 0;
							}
						} else {

							$v->{'inBuf'} .= $response->content;
							$v->{'fetching'} = 0;
							$v->{'retryCount'} = 0;
							$v->{'failureCount'} = 0;

							if (($v->{'endOffset'} > 0) && ($v->{'offset'} > $v->{'endOffset'})) {
								$v->{'streaming'} = 0;
								if ($props->{'isDynamic'}) {
									$props->{'isContinue'} = 1;
									$song->pluginData( props   => $props );
									main::INFOLOG && $log->is_info && $log->info('Dynamic track has ended and stream will continue');
								} else {
									Plugins::BBCSounds::ActivityManagement::heartBeat(getId($masterUrl),getPid($masterUrl),'ended',floor($props->{'duration'}));
								}
							}

							main::DEBUGLOG && $log->is_debug && $log->debug("got chunk $v->{'offset'} length: ",length $response->content," for $url");


							if ($props->{'isDynamic'}) {

								my $edge = $self->_calculateEdge($v->{'offset'}, $props);
								my $isNow = (Time::HiRes::time()-$edge) < 40;

								# check for live track if we are within striking distance of the live edge
								$self->liveTrackData($replOffset, $isNow, $v->{'firstIn'});

							} else {

								$self->liveTrackData($replOffset, 1, 0 );
							}
							$v->{'firstIn'} = 0;

							#increment until we reach the threshold to ensure we give the player enough playing data before taking up time getting meta data
							$v->{'resetMeta'}++ if $v->{'resetMeta'} > 0;
						}
					},

					onError => sub {

						$v->{'retryCount'}++;

						if ($v->{'retryCount'} > CHUNK_RETRYCOUNT) {

							$log->error("Failed to get $url");
							$v->{'failureCount'}++;
							$v->{'inBuf'}    = '';
							$v->{'fetching'} = 0;
							$v->{'streaming'} = 0
							  if ((($v->{'endOffset'} > 0) && ($v->{'offset'} > $v->{'endOffset'})) || $v->{'failureCount'} > CHUNK_FAILURECOUNT );
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

	if (my $bytes = min( length($v->{'outBuf'}), $maxBytes ) ) {
		main::DEBUGLOG && $log->is_debug && $log->debug('Bytes . ' . $maxBytes . ' . ' . length($v->{'outBuf'}) . ' . In Buf ' . length($v->{'inBuf'}));
		$_[1] = substr( $v->{'outBuf'}, 0, $bytes, '' );
		return $bytes;
	} elsif ( $v->{'streaming'} || $props->{'updatePeriod'} ) {
		main::DEBUGLOG && $log->is_debug && $log->debug('No bytes available' . Time::HiRes::time());

		#bbc heartbeat at a quiet time.
		if (!($self->isLive($masterUrl) || $self->isRewind($masterUrl))) {
			if ( time() > $v->{nextHeartbeat} ) {
				Plugins::BBCSounds::ActivityManagement::heartBeat(getId($masterUrl),getPid($masterUrl),'heartbeat',floor( $song->master->controller->playingSongElapsed ));
				$v->{nextHeartbeat} = time() + 30;
			}
		}
		$! = EINTR;
		return undef;
	}

	# end of streaming
	main::INFOLOG && $log->is_info && $log->info("end streaming " . length($v->{'inBuf'}));
	$props->{'updatePeriod'} = 0;

	return 0;
}


sub getId {
	my ( $url ) = @_;

	my @pid  = split /_/x, $url;
	my $vpid =  @pid[1];
	if ($vpid eq 'LIVE') {
		@pid  = split /_LIVE_/x, $url;
		$vpid =  @pid[1];
	}

	return $vpid;
}


sub getPid {
	my ( $url ) = @_;

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

	$masterUrl =~ s/&.*//;

	my $url = '';
	my $fallbackUrl = '';


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

		my $overrideEpoch;

		$overrideEpoch = (getRewindEpoch($masterUrl) + PROGRAMME_LATENCY) if $class->isRewind($masterUrl);

		getMPD(
			$url,
			\@allowDASH,
			sub {
				my $props = shift;
				return $errorCb->() unless $props;
				$song->pluginData( props   => $props );
				$song->pluginData( baseURL => $props->{'baseURL'} );
				if ( $props->{duration} ) {
					$song->duration( $props->{duration} );
					$song->isLive(0);
					aodSongMetaData ($song, $masterUrl, $props, sub {
						$setProperties->{ $props->{'format'} }( $song, $props, $successCb, sub {
							$log->warn("Failed to start stream, trying fallback url...");
							getMPD(
								$fallbackUrl,
								\@allowDASH,
								sub {
									my $props = shift;
									return $errorCb->() unless $props;
									$song->pluginData( props   => $props );
									$song->pluginData( baseURL => $props->{'baseURL'} );									
									$song->duration( $props->{duration} );
									$song->isLive(0);
									aodSongMetaData ($song, $masterUrl, $props, sub {
										$setProperties->{ $props->{'format'} }( $song, $props, $successCb, sub {
												$log->error("Fallback Error Failed");
												$errorCb->()
											}
										);
									});
								},
								$overrideEpoch
							);
						});
					});
				} else {
					liveSongMetaData( $song, $masterUrl, $props, 0, sub {
						my $updatedProps = shift;
						$song->isLive(1);
						$setProperties->{ $updatedProps->{'format'} }( $song, $updatedProps, $successCb, sub {
							$log->warn("Failed to start stream, trying fallback url...");
							getMPD(
								$fallbackUrl,
								\@allowDASH,
								sub {
									my $props = shift;
									return $errorCb->() unless $props;
									$song->pluginData( props   => $props );
									$song->pluginData( baseURL => $props->{'baseURL'} );									
									liveSongMetaData( $song, $masterUrl, $props, 0, sub {
										my $updatedProps = shift;
										$song->isLive(1);
										$setProperties->{ $updatedProps->{'format'} }( $song, $updatedProps, $successCb, sub {
												$log->error("Fallback Error Failed");
												$errorCb->()
											}
										); 
									});
								},									
								$overrideEpoch
							);
						}); 
					});				
				}				
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

				if ( $existingProps->{reverseSkip} ) {
					$existingProps->{comparisonTime} -= (($existingProps->{comparisonStartNumber} - $existingProps->{previousStartNumber})) * ($existingProps->{segmentDuration} / $existingProps->{segmentTimescale});
					$existingProps->{endNumber} = $existingProps->{startNumber} - 1;
					$existingProps->{startNumber} = $existingProps->{previousStartNumber};					
					$existingProps->{previousStartNumber} = 0;					
					$existingProps->{comparisonStartNumber} = $existingProps->{startNumber};

				} else {
				
					$existingProps->{comparisonTime} += (($existingProps->{endNumber} - $existingProps->{comparisonStartNumber}) + 1) * ($existingProps->{segmentDuration} / $existingProps->{segmentTimescale});
					$existingProps->{previousStartNumber} = $existingProps->{startNumber};
					$existingProps->{startNumber} = $existingProps->{endNumber} + 1;
					$existingProps->{comparisonStartNumber} = $existingProps->{startNumber};
					$existingProps->{endNumber} = 0;

				}
				
				liveSongMetaData( $song, $masterUrl, $existingProps, 0, sub { 
					my $updatedProps = shift;

					$updatedProps->{skip} = 0;
					$updatedProps->{reverseSkip} = 0;
					$song->pluginData( props   => $updatedProps );
					$song->isLive(1);
					main::INFOLOG && $log->is_info && $log->info("Continuation  of $masterUrl at " .$existingProps->{startNumber} );
					$successCb->();
					
				});
			
				return;
			}
		}

		$song->pluginData(
			meta => {
				title => $stationid,
				icon  => $class->getIcon(),
			}
		);

		Plugins::BBCSounds::SessionManagement::renewSession(
			sub {
				Plugins::BBCSounds::SessionManagement::getLiveStreamJwt(
					$stationid,
					sub {
						my $jwt = shift;
						_getMPDUrl(
							$stationid,
							sub {
								$url = shift;
								$fallbackUrl = shift;
								main::DEBUGLOG && $log->is_debug && $log->debug("mpd URL : $url fallback URL : $fallbackUrl ");
								$processMPD->();
							},
							sub {
								$log->error('Failed to get live MPD');
								$errorCb->("Not able to obtain live audio", $masterUrl);
							},
							$jwt,
						);
					},

					sub {
						$log->error('Could not get Live stream JWT');
						$errorCb->("Not able to obtain live audio, not logged in", $masterUrl);

					}
				);
			},
			sub {
				$log->error('Not logged in, cannot get audio');
				if (Slim::Utils::PluginManager->isEnabled('Plugins::MaterialSkin::Plugin')) {
					my $client = $song->master();
					Slim::Control::Request::notifyFromArray(undef, ['material-skin', 'notification', 'error', 'Cannot Play ' . $masterUrl . '. Not Signed In or Sign In expired.  Please sign in to your BBC Account in your LMS Server Settings', undef, $client->id()]);
				}
				$errorCb->("Not able to obtain live audio, not logged in", $masterUrl);
			}

		);

	} else {

		my $id = getId($masterUrl);

		$song->pluginData(
			meta => {
				title => $id,
				icon  => $class->getIcon(),
			}
		);

		Plugins::BBCSounds::SessionManagement::renewSession(
			sub {
				_getMPDUrl(
					$id,
					sub {
						$url = shift;
						$fallbackUrl = shift;
						main::DEBUGLOG && $log->is_debug && $log->debug("mpd URL : $url fallback URL : $fallbackUrl ");
						$processMPD->();
					},
					sub {
						$log->error('Failed to get Audio information.  It may not be available in your location.');
						$errorCb->("Not able to obtain audio", $masterUrl);
					}
				);
			},
			sub {
				$log->error('Not logged in, cannot get audio');
				if (Slim::Utils::PluginManager->isEnabled('Plugins::MaterialSkin::Plugin')) {
					my $client = $song->master();		
					Slim::Control::Request::notifyFromArray(undef, ['material-skin', 'notification', 'error', 'Cannot Play ' . $masterUrl . '. Not Signed In or Sign In expired.  Please sign in to your BBC Account in your LMS Server Settings', undef, $client->id()]);
				}
				$errorCb->("Not able to obtain live audio, not logged in", $masterUrl);
			}
		);

	}
}

sub aodSongMetaData {
	my ( $song, $masterUrl, $props, $cb ) = @_;
	
	my $pid =  getPid($masterUrl);


	_getAODMeta(
		$pid,
		sub {
			my $retMeta = shift;
			# the AOD meta is more accurate			
			$retMeta->{'duration'} = $props->{'duration'};

			if ( my $meta = $song->pluginData('meta') ) {  #Ensure the type is propagated through
				$retMeta->{type} = $meta->{type};
			}
			$song->pluginData( meta  => $retMeta );
			$cb->();		
			
		},
		sub {
			$log->warn('Could not retrieve AOD meta data ' . $pid);
		}

	);
	return;

}
sub liveSongMetaData {
	my ( $song, $masterUrl, $props, $retry, $cb) = @_;

	my $station = _getStationID($masterUrl);

	main::INFOLOG && $log->is_info && $log->info('Getting the meta data for new track');

	_getLiveSchedule(
		$station, $props,
		sub { #success shedule
			my $schedule = shift;
			main::DEBUGLOG && $log->is_debug && $log->debug('Have schedule for new track');
			#Check it is not empty
			my $items = $schedule->{data};			
			if (scalar(@$items) == 0 ) {
				if (!$retry) {
					$log->warn('Schedule empty cannot start audio, attempting workround....');
					liveSongMetaData( $song, $masterUrl, $props, 1, $cb );
					return;
				} else {
					$log->warn('Schedule still empty cannot start audio');
					return;
				}
			}
			
			my $resp = _getIDForBroadcast($schedule, $props->{startNumber}, $props);			
			if ($resp) {								
				_getLiveMeta(
					$resp->{id},
					sub {
						my $retMeta = shift;
						main::DEBUGLOG && $log->is_debug && $log->debug('Have new meta data for track');
						#set up chunk range						
						my $currentStartNumber = $props->{startNumber};
						$props->{startNumber} = $resp->{startOffset};
						$props->{endNumber} = $resp->{endOffset} if !$props->{endNumber};
						my $duration = calculateDurationFromChunks($props);
						$retMeta->{duration} = $duration;
						$props->{duration} = $duration;
						my $startTime = _timeFromOffset($currentStartNumber-$props->{startNumber}, $props);
						$song->duration( $props->{duration} );
						$song->seekdata($song->getSeekData($startTime));
						$song->startOffset( $startTime );
						$retMeta->{live_edge} = 1;
						main::DEBUGLOG && $log->is_debug && $log->debug('StartNumber: ' . $props->{startNumber} . ' EndNumber : ' . $props->{endNumber} . ' Duration : ' . $props->{duration} . " Seektime : $startTime Calculated From : $currentStartNumber ");

						$song->pluginData( meta  => $retMeta );
						
						#Finally, get the previous start number, if there is one and we haven't got one already						
						$props->{previousStartNumber} = 0;
					
						if ( my $lastresp = _getIDForBroadcast($schedule, $props->{startNumber} - 2, $props) ) {
							#We can only go back 6 hours
							if ( (time() - calculateTimeFromOffset($lastresp->{startOffset},$props)) < 21600 ) { 
								$props->{previousStartNumber} = $lastresp->{startOffset};
							}
							
						}
						$song->pluginData( props   => $props );
						$cb->($props);
					},					

					#failed
					sub {
						$log->warn('Could not retrieve live meta data ' . $masterUrl);						
					}
				);
			}
		},
		sub {
		$log->warn('Could not retrieve station schedule');
		},
		!$retry
	);
}


sub calculateDurationFromChunks {
	my ( $props ) = @_;

	my $duration =  (($props->{endNumber} - $props->{startNumber}) + 1) * ($props->{segmentDuration} / $props->{segmentTimescale});

	return $duration;

}

sub calculateTimeFromOffset { 
	my ( $offsetNumber, $props ) = @_;

	my $offsetTime =  $offsetNumber * ($props->{segmentDuration} / $props->{segmentTimescale});

	return $offsetTime;

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

							$props->{metaEpoch} = $props->{comparisonTime} - $epochTime;

							main::DEBUGLOG && $log->is_debug && $log->debug('dashtime : ' . $epochTime .  'comparision : ' . $props->{comparisonTime} . ' Segment duration : ' . $props->{segmentDuration} . ' Segment timescale : ' . $props->{segmentTimescale} );

							my $index = floor($epochTime / ($props->{segmentDuration} / $props->{segmentTimescale}));
							$props->{startNumber} = $index;
							$props->{comparisonStartNumber} = $index;

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
	my ( $class, $client, $full_url, $forceCurrent ) = @_;
	my $icon = $class->getIcon();

	my ($url) = $full_url =~ /([^&]*)/;
	my $id = getId($url) || return {};
	my $pid = '';
	my $song = $forceCurrent ? $client->streamingSong() : $client->playingSong();

	main::DEBUGLOG && $log->is_debug && $log->debug("getmetadata: $url  $forceCurrent");
	
	if ( $song && $song->currentTrack()->url eq $full_url ) {

		if (my $meta = $song->pluginData('meta')) {
			
			$song->track->secs( $meta->{duration} );
			my $buttons;
			
			if ($song->pluginData('nowPlayingButtons')) {
				if ($meta->{containerUrn} ne '') {
					$buttons = {
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
					$buttons = {
						repeat  => {
							icon    => Plugins::BBCSounds::Utilities::IMG_NOWPLAYING_BOOKMARK,
							jiveStyle => 'thumbsUp',
							tooltip => 'Bookmark the episode',
							command => [ 'sounds', 'bookmark', $meta->{urn} ],
						},
					};
				}
			}
			my $liveEdge = -1;
			if ($class->isLive($url)) {
				$liveEdge = $meta->{pausePoint} ? $meta->{live_edge} + (time() - $meta->{pausePoint}) : $meta->{live_edge};
			}
			return {
				artist => $meta->{artist},
				album  => $meta->{album},
				title  => $meta->{title},				
				duration => $meta->{duration},
				secs   => $meta->{duration},
				cover  => $meta->{cover},								
				buttons   => $buttons,
				live_edge => $liveEdge,
			}
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
	$pid = getPid($url);

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

	my $factor = ($props->{segmentDuration} / $props->{segmentTimescale});

	my $offsetEpoch = (($offset * $factor) - PROGRAMME_LATENCY) + $factor;

	my $items = $schedule->{data};

	main::DEBUGLOG && $log->is_debug && $log->debug("Finding $offset as $offsetEpoch in ");

	for my $item (@$items){
		if (($offsetEpoch >= str2time($item->{start})) && ($offsetEpoch < str2time($item->{end}))) {
			my $id = $item->{id};
			$id = $item->{pid} if !(defined $id); #sometimes it is the pid not the id.  I think this is an inconsistency in the API for previous broadcasts
			main::DEBUGLOG && $log->is_debug && $log->debug("Found in schedule -  $id  ");
			my $startOffset = floor(((str2time($item->{start})) + PROGRAMME_LATENCY) / $factor);
			my $endOffset = floor(((str2time($item->{end})) + PROGRAMME_LATENCY) / $factor) - 1;
			return {
				id => $id,
				secondsIn => (($offset - $startOffset)  * $factor),
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

				my $station = '';
				if (defined $json->{'network'}->{'short_title'}) {
					$station = $json->{'network'}->{'short_title'};
				}

				my $meta = {
					title			=> $title,
					realTitle 		=> $title,
					artist  		=> $syn,
					album 			=> $station,
					description 	=> $syn,
					duration 		=> $duration,
					icon     		=> $image,
					realIcon 		=> $image,
					cover    		=> $image,
					realCover 		=> $image,
					trackImage 		=> '',
					track 			=> '',
					spotify 		=> '',
					buttons 		=> undef,
					urn 			=> $urn,
					containerUrn 	=> $containerUrn,
					station 		=> $station,
				};
				$cache->set("bs:meta-$pid",$meta,86400);
				$cbY->($meta);

			},
			sub {
				#cache for 60 minutes so that we don't flood their api
				$log->warn("It looks like a player is asking for meta data that doesn't exist. Check that you have not got a player trying to get meta data for an old programme");
				my $failedmeta ={title => $pid,};
				$cache->set("bs:meta-$pid",$failedmeta,3600);
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

				my $stationName = '';
				if ( defined $json->{'network'}->{'long_title'} ) {
					$stationName = $json->{'network'}->{'long_title'};
				}

				my $meta = {
					title    		=> $title,
					realTitle 		=> $title,
					artist   		=> $syn,
					album			=> $stationName,
					description 	=> $syn,
					duration 		=> $duration,
					icon     		=> $image,
					realIcon 		=> $image,
					cover    		=> $image,
					realCover		=> $image,
					trackImage 		=> '',
					track 			=> '',
					spotify 		=> '',
					buttons 		=> undef,
					urn 			=> $urn,
					containerUrn 	=> '',
					station 		=> $stationName,
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
	my $jwt  = shift;

	my $url = "https://open.live.bbc.co.uk/mediaselector/6/select/version/2.0/mediaset/pc/vpid/$id/format/json";

	if ($jwt) {
		$url .= "?jwt_auth=$jwt";
	}
	
	main::DEBUGLOG && $log->is_debug && $log->debug("Media Selector URL  $url");

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
			my $mpd = '';
			my $fallbackmpd = '';			
			my $priority = 0;
			for my $connection (@$connections) {
				if ($connection->{transferFormat} eq 'dash' && $connection->{protocol} eq $protocol){
					if (!$priority) {
						$mpd = $connection->{href};
						$priority = int($connection->{priority});

						main::INFOLOG && $log->is_info && $log->info("MPD $mpd");
					} elsif ( ($connection->{priority} > int($priority)) ) {
						$fallbackmpd = $connection->{href};
						$cbY->($mpd, $fallbackmpd);
						return;
					}					
				}
			}
			if ($priority) {
				$cbY->($mpd);
				return;
			}
			$log->error("No Dash Found");
			$cbN->();
			return;
		},
		sub {
			$cbN->();
		}
	)->get($url);
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
	my $isLive = shift;

	if (   ($meta1->{title} eq $meta2->{title})
		&& ($meta1->{artist} eq $meta2->{artist})
		&& ($meta1->{album} eq $meta2->{album})
		&& ($meta1->{cover} eq $meta2->{cover})
		&& ($meta1->{track} eq $meta2->{track})
		&& (!$isLive || ($meta1->{live_edge} == $meta2->{live_edge})) ) {

		return;

	} else {

		main::INFOLOG && $log->is_info && $log->info("Meta Data Changed");
		return 1;
	}
}

1;
