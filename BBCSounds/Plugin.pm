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

my $prefs = preferences('plugin.bbcsounds');

$prefs->migrate(
	2,
	sub {
		$prefs->set('is_radio', 0);    
        $prefs->set('hideSampleRate', 0);    
		1;
	}
);


sub initPlugin {
	my $class = shift;

	$prefs->init({ is_radio => 0, hideSampleRate =>0 });


	$class->SUPER::initPlugin(
		feed   => \&Plugins::BBCSounds::BBCSoundsFeeder::toplevel,
		tag    => 'bbcsounds',
		menu   => 'radios',
		is_app => $class->can('nonSNApps') && (!($prefs->get('is_radio'))) ? 1 : undef,
		weight => 1,
	);

	if ( !$::noweb ) {
		require Plugins::BBCSounds::Settings;
		Plugins::BBCSounds::Settings->new;
	}

	return;
}

## not sure why we need the main::transcoding.  doing just in case.
sub postinitPlugin {
	if (main::TRANSCODING) {
		my $class = shift;

		Plugins::BBCSounds::BBCSoundsFeeder::init();
	}
}

sub getDisplayName { return 'PLUGIN_BBCSOUNDS'; }


sub playerMenu {
	my $class =shift;

    $log->info('Preference : ' . $prefs->get('is_radio'));

	if ($prefs->get('is_radio')  || (!($class->can('nonSNApps')))) {
		$log->info('Placing in Radio Menu');
		return 'RADIO';
	}else{
		$log->info('Placing in App Menu');
		return;
	}
}

1;
