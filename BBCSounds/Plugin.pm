package Plugins::BBCSounds::Plugin;

#  (c) stu@expectingtofly.co.uk  2023
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
use Plugins::BBCSounds::ListProtocolHandler;

use Data::Dumper;

my $log = Slim::Utils::Log->addLogCategory(
	{
		'category'     => 'plugin.bbcsounds',
		'defaultLevel' => 'WARN',
		'description'  => getDisplayName(),
	}
);

my $prefs = preferences('plugin.bbcsounds');



$prefs->migrate(
	12,
	sub {
		my $m = $prefs->get('homeMenu');
		if ( $m ) {
			my @collectionsonly = grep { $_->{item} eq 'collections'} @$m;
			if ( !(scalar @collectionsonly) ) {
				push @$m, { item => 'collections', title => 'Collections', display=>1, disabled=>0 } ;
				$prefs->set('homeMenu', $m);
			}
		}
		
		1;
	}
);


$prefs->migrate(
	11,
	sub {
		my $m = $prefs->get('homeMenu');
		if ( $m ) {
			my @newsonly = grep { $_->{item} eq 'news'} @$m;
			if ( !(scalar @newsonly) ) {
				push @$m, { item => 'news', title => 'All News', display=>0, disabled=>0 } ;
				$prefs->set('homeMenu', $m);
			}
		}
		
		1;
	}
);


$prefs->migrate(
	10,
	sub {
		my $m = $prefs->get('homeMenu');
		if ( $m ) {
			my $foundUnmissableSpeech = 0;
			my $foundUnmissableMusic = 0;
			for my $item (@$m) {
				if ($item->{item} eq 'unmissableSpeech') {
					$foundUnmissableSpeech = 1;
				}
				if ($item->{item} eq 'unmissableMusic') {
					$foundUnmissableMusic = 1;
				}
			}			
			push @$m, { item => 'unmissableSpeech', title => 'Discover Podcasts (Unmissable Speech)',display=>1, disabled=>0 } if !$foundUnmissableSpeech;
			push @$m, { item => 'unmissableMusic', title => 'Music You\'ll Love  (Unmissable Music)',display=>1, disabled=>0  } if !$foundUnmissableMusic;				
	
			
			#remove unmissable sounds
			my $index = 0;
			$index++ until ${$m}[$index]->{item} eq 'unmissibleSounds'; #it had a typo
			splice(@$m, $index, 1);
			$prefs->set('homeMenu', $m);

			#Ensure password is not stored in prefs
			$prefs->set('password', '');
		}
		
		1;
	}
);


$prefs->migrate(
	9,
	sub {
		my $m = $prefs->get('homeMenu');
		if ( $m ) {
			my $found = 0;
			for my $item (@$m) {
				if ($item->{item} eq 'listenLive') {
					$found = 1;
				}
			}
			if (!$found) {
				push @$m, { item => 'listenLive', title => 'Listen Live (Live Stations Only)',display=>1, disabled=>0 };
				$prefs->set('homeMenu', $m);
			}
		}
		1;
	}
);


$prefs->migrate(
	8,
	sub {
		#removed from beta version
		1;
	}
);


$prefs->migrate(
	7,
	sub {
		$prefs->set('forceHTTP', 0);
		1;
	}
);

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

	$prefs->init(
		{
			is_radio => 0,
			hideSampleRate => 0,
			programmedisplayline1 => Plugins::BBCSounds::ProtocolHandler::DISPLAYLINE_PROGRAMMETITLE,
			programmedisplayline2 => Plugins::BBCSounds::ProtocolHandler::DISPLAYLINE_PROGRAMMEDESCRIPTION,
			programmedisplayline3 => Plugins::BBCSounds::ProtocolHandler::DISPLAYLINE_STATIONNAME,
			programmedisplayimage => Plugins::BBCSounds::ProtocolHandler::DISPLAYIMAGE_PROGRAMMEIMAGE,
			trackdisplayline1 => Plugins::BBCSounds::ProtocolHandler::DISPLAYLINE_TRACK,
			trackdisplayline2 => Plugins::BBCSounds::ProtocolHandler::DISPLAYLINE_ARTIST,
			trackdisplayline3 => Plugins::BBCSounds::ProtocolHandler::DISPLAYLINE_PROGRAMMETITLE,
			trackdisplayimage => Plugins::BBCSounds::ProtocolHandler::DISPLAYIMAGE_TRACKIMAGE,
			forceHTTP => 0,
			nowPlayingActivityButtons => 1,
			throttleInterval => 1,
			playableAsPlaylist => 0,
			rewoundind => 1,
			homeMenu => [{ item => 'search', title => 'Search',display=>1, disabled=>1 },
						 { item => 'mySounds', title => 'My Sounds',display=>1, disabled=>1 },
						 { item => 'stations', title => 'Stations & Schedules',display=>1, disabled=>1 },
						 { item => 'unmissableSpeech', title => 'Discover Podcasts (Unmissable Speech)',display=>1, disabled=>0 },
						 { item => 'unmissableMusic', title => 'Music You\'ll Love (Unmissable Music)',display=>1, disabled=>0 },						 
						 { item => 'editorial', title => 'Promoted Editorial Content',display=>1, disabled=>0 },
						 { item => 'music', title => 'All Music', display=>1, disabled=>1 },
						 { item => 'podcasts', title => 'All Podcasts', display=>1, disabled=>1 },
						 { item => 'recommendations', title => 'Recommended For You', display=>1, disabled=>0 },
						 { item => 'localToMe', title => 'Local To Me',display=>1, disabled=>0 },
						 { item => 'categories', title => 'Browse Categories',display=>1, disabled=>1 },
						 { item => 'continueListening', title => 'Continue Listening',display=>0, disabled=>0 },
						 { item => 'SingleItemPromotion', title => 'Promoted Single Item',display=>1, disabled=>0 },
						 { item => 'listenLive', title => 'Listen Live (Live Stations Only)',display=>1, disabled=>0 },
						 { item => 'news', title => 'All News',display=>0, disabled=>0 },
						 { item => 'collections', title => 'Collections',display=>1, disabled=>0 },
						],
			noBlankTrackImage => 0,
			getExternalTrackImage => 1,
			isUKListenerAbroad => 0,
		}
	);

	# make sure the value is defined, otherwise it would be enabled again
	$prefs->setChange(
		sub {
			$prefs->set($_[0], 0) unless defined $_[1];
		},
		'nowPlayingActivityButtons'
	);
	$prefs->setChange(
		sub {
			$prefs->set($_[0], 0) unless defined $_[1];
		},
		'rewoundind'
	);

	$prefs->setChange(
		sub {
			$prefs->set($_[0], 0) unless defined $_[1];
		},
		'getExternalTrackImage'
	);

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

		# if user has the Don't Stop The Music plugin enabled, register ourselves
		if ( Slim::Utils::PluginManager->isEnabled('Slim::Plugin::DontStopTheMusic::Plugin') ) {

			Slim::Plugin::DontStopTheMusic::Plugin->registerHandler(
				'BBC Sounds Continue Listening',
				sub {
					my ($client, $cb) = @_;
					dontStopTheMusicContinue($client,$cb);
				}
			);
			Slim::Plugin::DontStopTheMusic::Plugin->registerHandler(
				'BBC Sounds Recommendations',
				sub {
					my ($client, $cb) = @_;
					dontStopTheMusicRecommended($client, '', $cb);
				}
			);
			Slim::Plugin::DontStopTheMusic::Plugin->registerHandler(
				'BBC Sounds Recommendations Music Mixes only',
				sub {
					my ($client, $cb) = @_;
					dontStopTheMusicRecommended($client, 'music', $cb);
				}
			);
		}
	}
}

sub getDisplayName { return 'PLUGIN_BBCSOUNDS'; }


sub playerMenu {
	my $class =shift;

	main::INFOLOG && $log->is_info && $log->info('Preference : ' . $prefs->get('is_radio'));

	if ($prefs->get('is_radio')  || (!($class->can('nonSNApps')))) {
		main::INFOLOG && $log->is_info && $log->info('Placing in Radio Menu');
		return 'RADIO';
	}else{
		main::INFOLOG && $log->is_info && $log->info('Placing in App Menu');
		return;
	}
}

sub dontStopTheMusicContinue {
	my ($client, $cb) = @_;
	Plugins::BBCSounds::BBCSoundsFeeder::getPersonalisedPage(
		undef,
		sub {
			my $res = shift;
			my $arr = $res->{items};
			my $ret = [];
			
			for my $item (@$arr) {
				my $playMenu = $item->{items};
				push @$ret, @$playMenu[0]->{url};
			}					
						
			$cb->($client, $ret);
		},
		undef,
		{type    => 'continue',	offset  => 0}
	);	
}

sub dontStopTheMusicRecommended {
	my ($client, $type, $cb) = @_;
	Plugins::BBCSounds::BBCSoundsFeeder::getPage(
		undef,
		sub {
			my $res = shift;
			my $arr = $res->{items};
			my $ret = [];
			for my $item (@$arr) {
				my $playMenu = $item->{items};
				push @$ret, @$playMenu[0]->{url};
			}					
			$cb->($client, $ret);
		},
		undef,
		{type    => 'recommendations' . $type,	offset  => 0}
	);
}

1;
