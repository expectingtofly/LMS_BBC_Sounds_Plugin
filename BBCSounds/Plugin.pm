package Plugins::BBCSounds::Plugin;

#  (c) stu@expectingtofly.co.uk  2020
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


use warnings;
use strict;

use base qw(Slim::Plugin::OPMLBased);

use Slim::Utils::Strings qw(string);
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Plugins::BBCSounds::BBCSoundsFeeder;
use Plugins::BBCSounds::ProtocolHandler;

my $log = Slim::Utils::Log->addLogCategory(
    {
        'category'     => 'plugin.bbcsounds',
        'defaultLevel' => 'ERROR',
        'description'  => getDisplayName(),
    }
);

sub initPlugin {
    my $class = shift;

    $class->SUPER::initPlugin(
        feed   => \&Plugins::BBCSounds::BBCSoundsFeeder::toplevel,
        tag    => 'bbcsounds',
        menu   => 'radios',
        is_app => $class->can('nonSNApps') ? 1 : undef,
        weight => 1,
    );

    if ( !$::noweb ) {
        require Plugins::BBCSounds::Settings;
        Plugins::BBCSounds::Settings->new;
    }

    return;
}

sub getDisplayName { return 'PLUGIN_BBCSOUNDS'; }

1;
