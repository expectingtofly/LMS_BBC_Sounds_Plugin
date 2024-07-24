package Plugins::BBCSounds::PlayManager;

#  (c) stu@expectingtofly.co.uk  2020
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

use warnings;
use strict;

use URI::Escape;
use JSON::XS::VersionOneAndTwo;

use Slim::Utils::Log;

my $log = logger('plugin.bbcsounds');


sub createIcon {
	my $url = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug("++createIcon");

	my $icon = $url; 

	$icon =~ s/{recipe}/320x320/;

	main::DEBUGLOG && $log->is_debug && $log->debug("--createIcon - $icon");
	return $icon;
}

sub getSoundsURLForPid {
	my $gpid = shift;
	my $cbY = shift;
	my $cbN = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug("++getSoundsURLForPid");

	my $playlist_url = URI->new('https://www.bbc.co.uk');
	$playlist_url->path_segments('programmes', $gpid, 'playlist.json');
	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;
			my $JSON = decode_json ${ $http->contentRef };
			my $pid = $JSON->{defaultAvailableVersion}->{pid};
			my $soundsUrl = 'sounds://_' . $pid . '_' . $gpid;
			$cbY->($soundsUrl);
		},
		sub {
			my ( $http, $error ) = @_;
			$log->error($error);
			$cbN->();
		},
	)->get($playlist_url);

	main::DEBUGLOG && $log->is_debug && $log->debug("--getSoundsURLForPid");
	return;
}

sub getTrackImageFromSpotifyUrl {
	my $spotifyUrl = shift;
	my $cbY = shift;
	my $cbN = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug("++getTrackImageFromSpotifyUrl");

	my $escapedSpotifyUrl = URI::Escape::uri_escape_utf8($spotifyUrl);
	my $url = "https://open.spotify.com/oembed?url=$escapedSpotifyUrl";
	
	main::DEBUGLOG && $log->is_debug && $log->debug("Getting image for $url");	

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;
			my $JSON = decode_json ${ $http->contentRef };
			my $image = $JSON->{thumbnail_url};		
			main::DEBUGLOG && $log->is_debug && $log->debug("Got image for $url");	
			$cbY->($image);
		},
		sub {
			my ( $http, $error ) = @_;
			$log->error($error);
			$cbN->();
		},
	)->get($url);

	main::DEBUGLOG && $log->is_debug && $log->debug("--getTrackImageFromSpotifyUrl");
	return;
}

1;

