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
    my $pid = shift;
    $log->debug("++createIcon");

    my $icon = "http://ichef.bbci.co.uk/images/ic/320x320/$pid.jpg";

    $log->debug("--createIcon - $icon");
    return $icon;
}


sub _placeImageRecipe {
    my $url = shift;
    $log->debug("++_placeImageRecipe");
    my $chars = "\\\$recipe";

    $url =~ s/$chars/320x320/ig;

    $log->debug("--_placeImageRecipe -  $url");
    return $url;
}

sub parsePlaylist {
    my $htmlref = shift;
    my $menu    = shift;
    my $gpid    = shift;

    $log->debug("++parsePlaylist");
    my $playlistJSON = decode_json $$htmlref;

    my $pid = $playlistJSON->{defaultAvailableVersion}->{pid};

    my $title = $playlistJSON->{defaultAvailableVersion}->{smpConfig}->{title};
    my $desc = $playlistJSON->{defaultAvailableVersion}->{smpConfig}->{summary};
    my $icon = createIcon(
        _getPidfromImageURL(
            $playlistJSON->{defaultAvailableVersion}->{smpConfig}
              ->{holdingImageURL}
        )
    );

    my $stream = 'sounds://_' . $pid . '_' . $gpid;

    $log->info("aod stream $stream");
    push @$menu,
      {
        'name'        => $title,
        'url'         => $stream,
        'icon'        => $icon,
        'type'        => 'audio',
        'description' => $desc,
        'on_select'   => 'play',
      };
    $log->debug("--parsePlaylist");
    return;
}

sub _getPidfromImageURL {
    my $url = shift;
    $log->debug("++_getPidfromImageURL");

    $log->debug("url to create pid : $url");
    my @pid = split /\//x, $url;
    my $pid = pop(@pid);
    $pid = substr $pid, 0, -4;

    $log->debug("--_getPidfromImageURL - $pid");
    return $pid;
}

1;

