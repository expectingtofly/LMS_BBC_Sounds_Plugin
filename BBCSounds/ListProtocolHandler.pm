# Copyright (C) 2020 stu@expectingtofly.co.uk
#
# This file is part of LMS_BBC_Sounds_Plugin.
#
# LMS_BBC_Sounds_Plugin is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# LMS_BBC_Sounds_Plugin is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with LMS_BBC_Sounds_Plugin.  If not, see <http://www.gnu.org/licenses/>.

package Plugins::BBCSounds::ListProtocolHandler;

use strict;

use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::BBCSounds::BBCSoundsFeeder;

Slim::Player::ProtocolHandlers->registerHandler('soundslist', __PACKAGE__);

my $log = logger('plugin.bbcsounds');

sub canDirectStream { 0 }
sub contentType { 'BBCSounds' }
sub isRemote { 1 }

sub explodePlaylist {
	my ( $class, $client, $url, $cb ) = @_;

	if ($main::VERSION lt '8.2.0') {
		$cb->(['BBC Sounds Favourites require LMS 8.2.0 or greater']);
		return;
	}

	my $type = _gettype($url);

    if ($type eq 'MYSOUNDS') {
        Plugins::BBCSounds::BBCSoundsFeeder::getSubMenu(undef, $cb, undef, {type => 'mysounds'});        
    } elsif ($type = 'CONTAINER') {
        my $pid = _getpid($url);
        Plugins::BBCSounds::BBCSoundsFeeder::getPage(undef, $cb, undef, {type    => 'tleo',	filter  => 'container=' . $pid,	offset  => 0});
    }	
}

sub _gettype {
	my $url  = shift;

	my @types  = split /_/x, $url;
	return @types[1];
}

sub _getpid {
	my $url  = shift;

	my @pids  = split /_/x, $url;
	return @pids[2];
}


1;

