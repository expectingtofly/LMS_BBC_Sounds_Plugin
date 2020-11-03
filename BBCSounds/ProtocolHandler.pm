package Plugins::BBCSounds::ProtocolHandler;

# Adapted from portions of Plugins:: (c) 2018, philippe_44@outlook.com
#
# Released under GPLv3
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 3
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

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

use constant MIN_OUT	=> 8192;
use constant DATA_CHUNK => 128*1024;	

my $log   = logger('plugin.bbcsounds');
my $cache = Slim::Utils::Cache->new;

Slim::Player::ProtocolHandlers->registerHandler('sounds', __PACKAGE__);

sub flushCache { $cache->cleanup(); }

my $setProperties  = { 	
						'aac' => \&Plugins::BBCSounds::M4a::setProperties 
				};
my $getAudio 	   = { 	
						'aac' => \&Plugins::BBCSounds::M4a::getAudio 
				};
my $getStartOffset = { 	
						'aac' => \&Plugins::BBCSounds::M4a::getStartOffset 
				};

sub canDoAction {
    my ( $class, $client, $url, $action ) = @_;
    
	main::INFOLOG && $log->is_info && $log->info( "action=$action" );
	
	return 1;
}


sub new {
	my $class = shift;
	my $args  = shift;
	my $song  = $args->{'song'};
	my $offset;
	my $props = $song->pluginData('props');
	
	return undef if !defined $props;
	
	main::DEBUGLOG && $log->is_debug && $log->debug( Dumper($props) );
	
	# erase last position from cache	
	$cache->remove("bs:lastpos-" . $class->getId($args->{'url'}));
						
	$args->{'url'} = $song->pluginData('baseURL');
	
	my $seekdata = $song->can('seekdata') ? $song->seekdata : $song->{'seekdata'};
	my $startTime = $seekdata->{'timeOffset'} || $song->pluginData('lastpos');
	$song->pluginData('lastpos', 0);
	  
	if ($startTime) {
		$song->can('startOffset') ? $song->startOffset($startTime) : ($song->{startOffset} = $startTime);
		$args->{'client'}->master->remoteStreamStartTime(Time::HiRes::time() - $startTime);
		$offset = undef;
	}
	
	main::INFOLOG && $log->is_info && $log->info("url: $args->{url} offset: ", $startTime || 0);
	
	my $self = $class->SUPER::new;
	
	if (defined($self)) {
		${*$self}{'client'} = $args->{'client'};
		${*$self}{'song'}   = $args->{'song'};
		${*$self}{'url'}    = $args->{'url'};
		${*$self}{'props'}  = $props;		
		${*$self}{'vars'}   = {        		# variables which hold state for this instance:
			'inBuf'       => '',      		# buffer of received data
			'outBuf'      => '',      		# buffer of processed audio
			'streaming'   => 1,      		# flag for streaming, changes to 0 when all data received
			'fetching'    => 0,		  		# waiting for HTTP data
			'offset'      => $offset,  		# offset for next HTTP request in webm/stream or segment index in dash
		};
	}
	
	# set starting offset (bytes or index) if not defined yet
	$getStartOffset->{$props->{'format'}}($args->{url}, $startTime, $props, sub { 
			${*$self}{'vars'}->{offset} = shift;
			$log->info("starting from offset ", ${*$self}{'vars'}->{offset}); 
		} 
	) if !defined $offset;
		
	# set timer for updating the MPD if needed (dash) 
	${*$self}{'active'}  = 1;		#SM Removed timer
	
	
	# for live stream, always set duration to timeshift depth
	#SM not supporting live stream
	$song->pluginData('liveStream', 0);
		
	return $self;
}

sub close {
	my $self = shift;
	
	${*$self}{'active'} = 0;		
	
	
	$self->SUPER::close(@_);
}

sub onStop {
    my ($class, $song) = @_;
	my $elapsed = $song->master->controller->playingSongElapsed;
	my $id = Plugins::BBCSounds::ProtocolHandler->getId($song->track->url);
	
	if ($elapsed < $song->duration - 15) {
		$cache->set("bs:lastpos-$id", int ($elapsed), '30days');
		$log->info("Last position for $id is $elapsed");
	} else {
		$cache->remove("bs:lastpos-$id");
	}	
}

sub onStream {
	my ($class, $client, $song) = @_;
	my $url = $song->track->url;
	
	#put start here?

}

sub formatOverride { 
	return $_[1]->pluginData('props')->{'format'};
}

sub contentType { 
	return ${*{$_[0]}}{'props'}->{'format'};
}

sub isAudio { 1 }

sub isRemote { 1 }

sub canDirectStream { 0 }

sub songBytes {}

sub canSeek { 1 }

sub getSeekData {
	my ($class, $client, $song, $newtime) = @_;
	return { timeOffset => $newtime };
}

sub vars {
	return ${*{$_[0]}}{'vars'};
}

my $nextWarning = 0;

sub sysread {
	use bytes;

	my $self  = $_[0];
	# return in $_[1]
	my $maxBytes = $_[2];
	my $v = $self->vars;
	my $baseURL = ${*$self}{'url'};
	my $props = ${*$self}{'props'};
	
	# means waiting for offset to be set
	if ( !defined $v->{offset} ) {
		$! = EINTR;
		return undef;
	}
		
	# need more data
	if ( length $v->{'outBuf'} < MIN_OUT && !$v->{'fetching'} && $v->{'streaming'} ) {
		my $url = $baseURL;
		my @range;
		
		$url .= $props->{'segmentURL'};		
		my $replOffset = ($v->{'offset'} + 1);
		
		$url =~ s/\$Number\$/$replOffset/;
		$v->{'offset'}++;
						
		$v->{'fetching'} = 1;		
		
		Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				$v->{'inBuf'} .= $_[0]->content;
				$v->{'fetching'} = 0;
				
				$v->{'streaming'} = 0 if $v->{'offset'} == ($props->{'endNumber'}-1);
				main::DEBUGLOG && $log->is_debug && $log->debug("got chunk $v->{'offset'} length: ", length $_[0]->content, " for $url");
						
			},

			sub {
				if (main::DEBUGLOG && $log->is_debug) {
					$log->debug("error fetching $url")
				}
				# only log error every x seconds - it's too noisy for regular use
				elsif (time() > $nextWarning) {
					$log->warn("error fetching $url");
					$nextWarning = time() + 10;
				}

				$v->{'inBuf'} = '';
				$v->{'fetching'} = 0;
			}, 
			
		)->get($url, @range);
	}	

	# process all available data	
	$getAudio->{$props->{'format'}}($v, $props) if length $v->{'inBuf'};
	
	if ( my $bytes = min(length $v->{'outBuf'}, $maxBytes) ) {
		$_[1] = substr($v->{'outBuf'}, 0, $bytes);
		$v->{'outBuf'} = substr($v->{'outBuf'}, $bytes);
		return $bytes;
	} elsif ( $v->{'streaming'} || $props->{'updatePeriod'} ) {
		$! = EINTR;
		return undef;
	}	
	
	# end of streaming and make sure timer is not running
	main::INFOLOG && $log->is_info && $log->info("end streaming");
	$props->{'updatePeriod'} = 0;
	
	return 0;
}

sub getId {
	my ($class, $url) = @_;
    
    my @pid = split /\/\/:/x, $url;
    my $pid = pop(@pid);
    
    return $pid;
}

# fetch the YouTube player url and extract a playable stream
sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;
	my $masterUrl = $song->track()->url;
	
	$song->pluginData(lastpos => ($masterUrl =~ /&lastpos=([\d]+)/)[0] || 0);
	$masterUrl =~ s/&.*//;
	
	my $id = $class->getId($masterUrl);
		
	#sm	  sounds://PID
	my $url = 'http://open.live.bbc.co.uk/mediaselector/6/redir/version/2.0/mediaset/audio-syndication-dash/proto/http/vpid/' . substr $masterUrl, 9;
		
	my @allowDASH = (); 	
	
	main::INFOLOG && $log->is_info && $log->info("url: $url master: $masterUrl");
	
	push @allowDASH, ( ['audio_eng=320000', 'aac', 320_000], ['audio_eng=128000', 'aac', 128_000], ['audio_eng_1=96000', 'aac', 96_000], ['audio_eng_1=48000', 'aac', 48_000] );
	@allowDASH = sort {@$a[2] < @$b[2]} @allowDASH;

	my $dashmpd = $url;
		getMPD($dashmpd, \@allowDASH, sub {
					my $props = shift;
					return $errorCb->() unless $props;
					$song->pluginData(props => $props);
					$song->pluginData(baseURL  => $props->{'baseURL'});
					$setProperties->{$props->{'format'}}($song, $props, $successCb);
				} );	
}


sub getMPD {
	my ($dashmpd, $allow, $cb) = @_;	
	
	my $session = Slim::Networking::Async::HTTP->new;
    my $mpdrequest = HTTP::Request->new( GET => $dashmpd );
    $session->send_request(
        {
            request => $mpdrequest,
            onBody  => sub {
			    my ( $http, $self ) = @_;
                my $res = $http->response;
                my $req = $http->request;
				
				my $endURI =  URI->new($res->base);
				my $startBase = 'http://' . $endURI->host . dirname($endURI->path) . '/';				
			
				my $selIndex;
				my ($selRepres, $selAdapt);
				my $mpd = XMLin( $res->content, KeyAttr => [], ForceContent => 1, ForceArray => [ 'AdaptationSet', 'Representation', 'Period' ] );
				my $period = $mpd->{'Period'}[0];
				my $adaptationSet = $period->{'AdaptationSet'}; 
				
				$log->error("Only one period supported") if @{$mpd->{'Period'}} != 1;
																							
				# find suitable format, first preferred
				foreach my $adaptation (@$adaptationSet) {
					if ($adaptation->{'mimeType'} eq 'audio/mp4') {
																																		
						foreach my $representation (@{$adaptation->{'Representation'}}) {
							
							next unless my ($index) = grep { $$allow[$_][0] eq $representation->{'id'} } (0 .. @$allow-1);
							main::INFOLOG && $log->is_info && $log->info("found matching format $representation->{'id'}");
							next unless !defined $selIndex || $index < $selIndex;												
							$selIndex = $index;
							$selRepres = $representation;
							$selAdapt = $adaptation;
						}	
					}	
				}
				
				# might not have found anything	
				return $cb->() unless $selRepres;
				main::INFOLOG && $log->is_info && $log->info("selected $selRepres->{'id'}");
								
							
				my $duration = $mpd->{'mediaPresentationDuration'};
				my ($misc, $hour, $min, $sec) = $duration =~ /P(?:([^T]*))T(?:(\d+)H)?(?:(\d+)M)?(?:([+-]?([0-9]*[.])?[0-9]+)S)?/;
				$duration = ($sec || 0) + (($min || 0) * 60) + (($hour || 0) * 3600);
										
				main::INFOLOG && $log->is_info && $log->info("MPD duration $duration");
													
				my $props = {
						format 			=> $$allow[$selIndex][1],
						updatePeriod	=> 0,
						baseURL 		=> $startBase . ($selRepres->{'BaseURL'}->{'content'} // 
										   $selAdapt->{'BaseURL'}->{'content'} // 
										   $period->{'BaseURL'}->{'content'} // 
										   $mpd->{'BaseURL'}->{'content'}),						
						segmentTimescale => $selRepres->{'SegmentTemplate'}->{'timescale'} // 
										   $selAdapt->{'SegmentTemplate'}->{'timescale'} //
										   $period->{'SegmentTemplate'}->{'timescale'},
						segmentDuration	=> $selRepres->{'SegmentTemplate'}->{'duration'} // 
										   $selAdapt->{'SegmentTemplate'}->{'duration'} // 
										   $period->{'SegmentTemplate'}->{'duration'},
						segmentURL		=> $selRepres->{'SegmentTemplate'}->{'media'} // 
										   $selAdapt->{'SegmentTemplate'}->{'media'} // 
										   $period->{'SegmentTemplate'}->{'media'},
						initializeURL	=> $selRepres->{'SegmentTemplate'}->{'initialization'} // 
										   $selAdapt->{'SegmentTemplate'}->{'initialization'} // 
										   $period->{'SegmentTemplate'}->{'initialization'},
						endNumber       => 1,						
						startNumber		=> 1,
						samplingRate	=> $selRepres->{'audioSamplingRate'} // 
										   $selAdapt->{'audioSamplingRate'},
						channels		=> $selRepres->{'AudioChannelConfiguration'}->{'value'} // 
										   $selAdapt->{'AudioChannelConfiguration'}->{'value'},
						bitrate			=> $selRepres->{'bandwidth'},
						duration		=> $duration,
						timescale		=> 1,
						timeShiftDepth	=> 0,
						mpd				=> { url => $dashmpd, type => $mpd->{'type'}, 
											 adaptId => $selAdapt->{'id'}, represId => $selRepres->{'id'}, 
						},	 
					};	
				
				#fix urls
				$props->{initializeURL} =~ s/\$RepresentationID\$/$selRepres->{id}/;
				$props->{segmentURL} =~ s/\$RepresentationID\$/$selRepres->{id}/;
				$props->{endNumber} = ceil($duration / ($props->{segmentDuration} / $props->{segmentTimescale}));
													
				$cb->($props);
			},
			onError =>
				sub {
					$log->error("cannot get MPD file $dashmpd");
					$cb->();
				}
			});
}

sub getMetadataFor {
	my ($class, $client, $full_url) = @_;
	#my $icon = $class->getIcon();
	
	my ($url) = $full_url =~ /([^&]*)/;				
	my $id = $class->getId($url) || return {};
	
	main::DEBUGLOG && $log->is_debug && $log->debug("getmetadata: $url");
		
	if (my $meta = $cache->get("bs:meta-$id")) {
		my $song = $client->playingSong();

		if ($song && $song->currentTrack()->url eq $full_url) {
			$song->track->secs( $meta->{duration} );
			#if (defined $meta->{_thumbnails}) {
				#$meta->{cover} = $meta->{icon} = Plugins::YouTube::Plugin::_getImage($meta->{_thumbnails}, 1);				
				#delete $meta->{_thumbnails};
				#$cache->set("yt:meta-$id", $meta);
				#main::INFOLOG && $log->is_info && $log->info("updating thumbnail cache with hires $meta->{cover}");
			#}
		}	
				
		main::DEBUGLOG && $log->is_debug && $log->debug("cache hit: $id");
		
		return $meta;
	}
	
	if ($client->master->pluginData('fetchingYTMeta')) {
		main::DEBUGLOG && $log->is_debug && $log->debug("already fetching metadata: $id");
		return {	
			type	=> 'BBCSounds',
			title	=> $url,
			#icon	=> $icon,
			#cover	=> $icon,
		};	
	}
	
	## Go fetch metadata for all tracks on the playlist without metadata
	#my $pageCall;

	#$pageCall = sub {
		#my ($status) = @_;
		#my @need;
		
		#for my $track ( @{ Slim::Player::Playlist::playList($client) } ) {
			#my $trackURL = blessed($track) ? $track->url : $track;
			#if ( $trackURL =~ m{youtube:/*(.+)} ) {
				#my $trackId = $class->getId($trackURL);
				#if ( $trackId && !$cache->get("yt:meta-$trackId") ) {
					#push @need, $trackId;
				#}
				#elsif (!$trackId) {
					#$log->warn("No id found: $trackURL");
				#}
			
				## we can't fetch more than 50 at a time
				#last if (scalar @need >= 50);
			#}
		#}
						
		#if (scalar @need && !defined $status) {
			#my $list = join( ',', @need );
			#main::INFOLOG && $log->is_info && $log->info( "Need to fetch metadata for: $list");
			#_getBulkMetadata($client, $pageCall, $list);
		#} else {
			#$client->master->pluginData(fetchingYTMeta => 0);
			#if ($status) {
				#$client->currentPlaylistUpdateTime( Time::HiRes::time() );
				#Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );	
			#}	
		#} 
	#};

	#$client->master->pluginData(fetchingYTMeta => 1);
	
	## get the one item if playlist empty
	#if ( Slim::Player::Playlist::count($client) ) { $pageCall->() }
	#else { _getBulkMetadata($client, undef, $id) }
		
	return {	
			type	=> 'BBCSounds',
			title	=> 'no meta yet',
			#icon	=> $icon,
			#cover	=> $icon,
	};
}	


sub getIcon {
	my ( $class, $url ) = @_;
	
	return;

	#return Plugins::YouTube::Plugin->_pluginDataFor('icon');
}



1;
