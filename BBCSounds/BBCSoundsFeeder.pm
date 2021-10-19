package Plugins::BBCSounds::BBCSoundsFeeder;

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

use warnings;
use strict;

use URI::Escape;
use URI;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Networking::Async::HTTP;
use Slim::Utils::Cache;
use JSON::XS::VersionOneAndTwo;
use POSIX qw(strftime);
use HTTP::Date;
use Digest::MD5 qw(md5_hex);
use Slim::Utils::Strings qw(string cstring);

use Data::Dumper;

use Plugins::BBCSounds::PlayManager;
use Plugins::BBCSounds::SessionManagement;
use Plugins::BBCSounds::ActivityManagement;
use Plugins::BBCSounds::Utilities;

my $log = logger('plugin.bbcsounds');
my $prefs = preferences('plugin.bbcsounds');

my $cache = Slim::Utils::Cache->new();
sub flushCache { $cache->cleanup(); }


sub init {


	Slim::Menu::TrackInfo->registerInfoProvider(
		bbcsounds => (
			after => 'top',
			func  => \&soundsInfoIntegration,
		)
	);


	Slim::Menu::GlobalSearch->registerInfoProvider(
		bbcsounds => (
			func => sub {
				my ( $client, $tags ) = @_;

				return {
					name  => cstring($client, Plugins::BBCSounds::Plugin::getDisplayName()),
					items => [ map { delete $_->{image}; $_ } @{_globalSearchItems($client, $tags->{search})} ],
				};
			},
		)
	);

	#                                                               |requires Client
	#                                                               |  |is a Query
	#                                                               |  |  |has Tags
	#                                                               |  |  |  |Function to call
	#                                                               C  Q  T  F
	Slim::Control::Request::addDispatch(['sounds','recentsearches'],[0, 0, 1, \&_recentSearchesCLI]);
	Slim::Control::Request::addDispatch(['sounds','subscribeUnsubscribe'],[0, 0, 1, \&_subscribeCLI]);

	Slim::Control::Request::addDispatch(['sounds', 'bookmark', '_urn'],[0, 1, 1, \&buttonBookmark]);

	Slim::Control::Request::addDispatch(['sounds', 'subscribe', '_urn'],[0, 1, 1, \&buttonSubscribe]);

	_removeCacheMenu('toplevel'); #force remove
}


sub toplevel {
	my ( $client, $callback, $args ) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++toplevel");

	my $menu = [];

	#Obtain the variable editorial content title

	my $fetch;

	$fetch = sub {
		$menu = [
			{
				name        => 'Music',
				type        => 'link',
				url         => '',
				image => Plugins::BBCSounds::Utilities::IMG_MUSIC,
				passthrough => [ { type => 'music', codeRef => 'getPage' } ],
				order       => 6,
			},
			{
				name => 'My Sounds',
				type => 'link',
				url  => '',
				favorites_url => 'soundslist://_MYSOUNDS',
				favorites_type	=> 'link',
				playlist => 'soundslist://_MYSOUNDS',
				image => Plugins::BBCSounds::Utilities::IMG_MY_SOUNDS,
				passthrough =>[ { type => 'mysounds', codeRef => 'getSubMenu' } ],
				order => 2,
			},
			{
				name => 'Stations & Schedules',
				type => 'link',
				image => Plugins::BBCSounds::Utilities::IMG_STATIONS,
				url  => '',
				passthrough =>[ { type => 'stationlist', codeRef => 'getPage' } ],
				order => 3,
			},
			{
				name => 'Browse Categories',
				type => 'link',
				image => Plugins::BBCSounds::Utilities::IMG_BROWSE_CATEGORIES,
				url  => '',
				passthrough =>[ { type => 'categories', codeRef => 'getSubMenu' } ],
				order => 9,
			},
			{
				name        => 'Podcasts',
				type        => 'link',
				url         => '',
				image => Plugins::BBCSounds::Utilities::IMG_SUBSCRIBE,
				passthrough => [ { type => 'podcasts', codeRef => 'getPage' } ],
				order       => 7,
			},
		];

		if (Plugins::BBCSounds::Utilities::hasRecentSearches()) {
			push @$menu,{

				name        => 'Search',
				type        => 'link',
				image => Plugins::BBCSounds::Utilities::IMG_SEARCH,
				url         => '',
				passthrough => [ { codeRef => 'recentSearches' } ],
				order       => 1,
			};

		} else {
			push @$menu,{

				name        => 'Search',
				type        => 'search',
				image => Plugins::BBCSounds::Utilities::IMG_SEARCH,
				url         => '',
				passthrough => [ { type => 'search', codeRef => 'getPage' } ],
				order       => 1,

			};
		}


		my $callurl = 'https://rms.api.bbc.co.uk/v2/my/experience/inline/listen';
		main::DEBUGLOG && $log->is_debug && $log->debug("fetching: $callurl");

		Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				my $http = shift;
				my $JSON = decode_json ${ $http->contentRef };

				#Priority Brand menu (unmissable Sounds)
				my $module = _parseTopInlineMenu($JSON, 'priority_brands');
				my $moduleTitle = $module->{title};
				my $submenu = [];

				if ($module->{total}) {
					_parseItems( $module->{data}, $submenu );
					push @$menu,
					  {
						name  => $moduleTitle,
						type  => 'link',
						image  => Plugins::BBCSounds::Utilities::IMG_FEATURED,
						items => $submenu,
						order => 4,
					  };
				}

				#Editorial menu
				$module = _parseTopInlineMenu($JSON, 'editorial_collection');
				$moduleTitle = $module->{title};
				$submenu = [];

				if ($module->{total}) {
					_parseItems( $module->{data}, $submenu );
					push @$menu,
					  {
						name  => $moduleTitle,
						type  => 'link',
						image  => Plugins::BBCSounds::Utilities::IMG_EDITORIAL,
						items => $submenu,
						order => 5,
					  };
				}

				#Recommended
				$module = _parseTopInlineMenu($JSON, 'recommendations');
				$moduleTitle = $module->{title};
				$submenu = [];

				if ($module->{total}) {
					_parseItems( $module->{data}, $submenu );
					push @$menu,
					  {
						name  => $moduleTitle,
						type  => 'link',
						image => Plugins::BBCSounds::Utilities::IMG_RECOMMENDATIONS,
						items => $submenu,
						order => 8,
					  };
				}


				#single item promo
				$module = _parseTopInlineMenu($JSON, 'single_item_promo');
				if ($module->{total}) {

					#There will only be one
					my $promo = $module->{data};
					my $singlePromo = @$promo[0];
					$moduleTitle = '';
					$moduleTitle .= $singlePromo->{titles}->{tertiary} . ' ' if  defined $singlePromo->{titles}->{tertiary};
					$moduleTitle .= $singlePromo->{titles}->{primary} . ' - ' . $singlePromo->{titles}->{secondary};
					$submenu = [];
					my $dataArr = [];
					push @$dataArr, $singlePromo->{item};

					#some times it points to a live network
					if ( $singlePromo->{item}->{urn} =~ /:network:/) {
						push @$submenu,
						  {
							name        => $moduleTitle,
							type        => 'audio',
							image        =>  Plugins::BBCSounds::PlayManager::createIcon($singlePromo->{item}->{image_url}),
							url         => 'sounds://_LIVE_'. $singlePromo->{item}->{id},
							on_select   => 'play'
						  };

					} else {
						_parseItems($dataArr, $submenu);
					}


					if (scalar @$submenu ) {

						#fix up
						@$submenu[0]->{order} = 10;
						@$submenu[0]->{name} = $moduleTitle;
						push @$menu, @$submenu[0];
					}
				}


				@$menu = sort { $a->{order} <=> $b->{order} } @$menu;
				_cacheMenu( 'toplevel', $menu, 500 );
				_renderMenuCodeRefs($menu);
				$callback->($menu);
			},

			# Called when no response was received or an error occurred.
			sub {
				$log->warn("error: $_[1]");

				#sort the list by order
				@$menu = sort { $a->{order} <=> $b->{order} } @$menu;
				_cacheMenu( 'toplevel', $menu, 60 );
				_renderMenuCodeRefs($menu);
				$callback->($menu);
			}
		)->get($callurl);
	};

	if ( my $cachemenu = _getCachedMenu('toplevel') ) {
		main::DEBUGLOG && $log->is_debug && $log->debug("Have cached menu");
		_renderMenuCodeRefs($cachemenu);
		$callback->( { items => $cachemenu } );
	}else {
		main::DEBUGLOG && $log->is_debug && $log->debug("No cache");
		if ( Plugins::BBCSounds::SessionManagement::isSignedIn() ) {
			Plugins::BBCSounds::SessionManagement::renewSession(
				sub {
					$fetch->();
				},
				sub {
					$menu = [
						{
							name =>'Not Signed In!  Please sign in to your BBC Account in your LMS Server Settings'
						}
					];
					$callback->( { items => $menu } );
				}
			);
		}else {
			$menu = [
				{
					name =>'Not Signed In!  Please sign in to your BBC Account in your LMS Server Settings'
				}
			];
			$callback->( { items => $menu } );
		}
	}

	main::DEBUGLOG && $log->is_debug && $log->debug("--toplevel");
	return;
}


sub getPage {
	my ( $client, $callback, $args, $passDict ) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++getPage");

	my $menuType    = $passDict->{'type'};
	my $callurl     = "";
	my $denominator = "";
	my $cacheIt     = 1;

	if ( $menuType eq 'stationlist' ) {
		$callurl = 'https://rms.api.bbc.co.uk/v2/experience/inline/stations';
	}elsif ( $menuType eq 'tleo' ) {
		$callurl ='https://rms.api.bbc.co.uk/v2/my/programmes/playable?sort=-release_date&'. $passDict->{'filter'} . '&offset='. $passDict->{'offset'};
		$denominator = "";
	}elsif ( $menuType eq 'inlineURN' ) {
		$callurl ='https://rms.api.bbc.co.uk/v2/experience/inline/container/'.  $passDict->{'urn'}. '?&offset='. $passDict->{'offset'};
		$denominator = "";
	}elsif ( $menuType eq 'container' ) {
		$callurl ='https://rms.api.bbc.co.uk/v2/programmes/playable?category=' . $passDict->{'category'} . '&tleoDistinct=true&offset='. $passDict->{'offset'};
		$denominator = $passDict->{'category'};
	}elsif ( $menuType eq 'search' ) {
		my $searchstr = '';
		if ($passDict->{'recent'} ) {
			$searchstr = $passDict->{'query'};
		} else {
			$searchstr = $args->{'search'};
			Plugins::BBCSounds::Utilities::addRecentSearch($searchstr);
		}
		$callurl ='https://rms.api.bbc.co.uk/v2/experience/inline/search?q='. URI::Escape::uri_escape_utf8($searchstr);
		$cacheIt = 0;
		if (Plugins::BBCSounds::Utilities::hasRecentSearches != 1 ) { 	_removeCacheMenu('toplevel'); }    #make sure the new search menu appears at the top level to save confusion.
	}elsif ( $menuType eq 'searchshows' ) {
		my $searchstr = URI::Escape::uri_escape_utf8( $passDict->{'query'} );
		$callurl ='https://rms.api.bbc.co.uk/v2/programmes/search/container?q='. $searchstr;
		$cacheIt = 0;
	}elsif ( $menuType eq 'searchepisodes' ) {
		my $searchstr = URI::Escape::uri_escape_utf8( $passDict->{'query'} );
		$callurl ='https://rms.api.bbc.co.uk/v2/programmes/search/playable?q='. $searchstr;
		$cacheIt = 0;
	}elsif ( $menuType eq 'searchall' ) {
		my $searchstr = URI::Escape::uri_escape_utf8( $passDict->{'query'} );
		$callurl ='https://rms.api.bbc.co.uk/v2/experience/inline/search?q='. $searchstr;
		$cacheIt = 0;
	}elsif ( $menuType eq 'categories' ) {
		$callurl = 'https://rms.api.bbc.co.uk/v2/categories/container?kind='. $passDict->{'categorytype'};
	}elsif ( $menuType eq 'childcategories' ) {
		$callurl ='https://rms.api.bbc.co.uk/v2/categories/' . $passDict->{'category'};
	}elsif ( $menuType eq 'stationsdayschedule' ) {
		$callurl ='https://rms.api.bbc.co.uk/v2/experience/inline/schedules/'. $passDict->{'stationid'} . '/'. $passDict->{'scheduledate'};
	}elsif ( $menuType eq 'segments' ) {
		$callurl = 'https://rms.api.bbc.co.uk/v2/versions/' . $passDict->{'id'} . '/segments';
	}elsif ( $menuType eq 'stationfeatured' ) {
		$callurl = 'https://rms.api.bbc.co.uk/v2/networks/' . $passDict->{'stationid'} . '/promos/playable';
	}elsif ( $menuType eq 'podcasts' ) {
		$callurl ='https://rms.api.bbc.co.uk/v2/experience/inline/speech';
	}elsif ( $menuType eq 'music' ) {
		$callurl ='https://rms.api.bbc.co.uk/v2/experience/inline/music';
	}else {
		$log->error("Invalid menu selection");
	}
	my $menu = [];
	my $fetch;

	$fetch = sub {

		main::DEBUGLOG && $log->is_debug && $log->debug("fetching: $callurl");

		Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				my $http = shift;
				_parse( $http, $menuType, $menu, $denominator, $passDict );
				if ($cacheIt) { _cacheMenu( $callurl, $menu, 600); }
				_renderMenuCodeRefs($menu);
				$callback->( { items => $menu } );
			},

			# Called when no response was received or an error occurred.
			sub {
				$log->warn("error: $_[1]");
				$callback->( [ { name => $_[1], type => 'text' } ] );
			}
		)->get($callurl);
	};

	if ( $cacheIt && ( my $cachemenu = _getCachedMenu($callurl) ) ) {
		main::DEBUGLOG && $log->is_debug && $log->debug("Have cached menu");
		_renderMenuCodeRefs($cachemenu);
		$callback->( { items => $cachemenu } );
	}else {
		main::DEBUGLOG && $log->is_debug && $log->debug("No cache");
		$fetch->();
	}

	main::DEBUGLOG && $log->is_debug && $log->debug("--getPage");
	return;
}


sub getStationMenu {
	my ( $client, $callback, $args, $passDict ) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++getStationMenu");

	my $now       = time();
	my $stationid = $passDict->{'stationid'};
	my $NetworkDetails = $passDict->{'networkDetails'};

	my $scheduleMenu = [];
	my $olderMenu = [];


	for ( my $i = 0 ; $i < 30 ; $i++ ) {
		my $d = '';
		my $epoch = $now - ( 86400 * $i );
		if ( $i == 0 ) {
			$d = 'Today';
		}elsif ( $i == 1 ) {
			$d = 'Yesterday (' . strftime( '%A', localtime($epoch) ) . ')';
		}else {
			$d = strftime( '%A %d/%m', localtime($epoch) );
		}

		my $scheduledate = strftime( '%Y-%m-%d', localtime($epoch) );

		my $menuItem = {
			name        => $d,
			type        => 'link',
			url         => \&getPage,
			passthrough => [
				{
					type         => 'stationsdayschedule',
					stationid    => $stationid,
					scheduledate => $scheduledate,
					codeRef      => 'getPage'
				}
			],
		};

		if ($i < 7) {
			push @$scheduleMenu, $menuItem;
		}

		push @$olderMenu, $menuItem;

	}

	my $menu      = [
		{
			name        => $NetworkDetails->{short_title} . ' LIVE',
			type        => 'audio',
			image        =>  Plugins::BBCSounds::Utilities::createNetworkLogoUrl($NetworkDetails->{logo_url}),
			url         => 'sounds://_LIVE_'. $stationid,
			on_select   => 'play'
		}
	];

	push @$menu, @$scheduleMenu;
	push @$menu,
	  {
		name        => $NetworkDetails->{short_title} . ' Highlights',
		type        => 'link',
		url         => \&getPage,
		passthrough => [
			{
				type         => 'stationfeatured',
				stationid    => $stationid,
				codeRef      => 'getPage'
			}
		],
	  };

	push @$menu,
	  {
		name        => 'Full 30 Day Schedule',
		type        => 'link',
		items       => $olderMenu
	  };


	$callback->( { items => $menu } );
	main::DEBUGLOG && $log->is_debug && $log->debug("--getStationMenu");
	return;
}


sub getPersonalisedPage {
	my ( $client, $callback, $args, $passDict ) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++getPersonalisedPage Args : " . Dumper($args));

	my $menuType = $passDict->{'type'};
	my $callurl  = "";
	my $cacheIt = 1;

	my $offset = '';
	if (defined $passDict->{'offset'}) {
		$offset = '?offset='. $passDict->{'offset'};
	}

	if ( $menuType eq 'latest' ) {
		$callurl ='https://rms.api.bbc.co.uk/v2/my/programmes/follows/playable' . $offset;
	}elsif ( $menuType eq 'subscribed' ) {
		$callurl = 'https://rms.api.bbc.co.uk/v2/my/programmes/follows' . $offset;
	}elsif ( $menuType eq 'bookmarks' ) {
		$callurl ='https://rms.api.bbc.co.uk/v2/my/programmes/favourites/playable' . $offset;
	}elsif ( $menuType eq 'continue' ) {
		$callurl = 'https://rms.api.bbc.co.uk/v2/my/programmes/plays/playable' . $offset;
	}

	my $menu        = [];
	my $denominator = '';
	my $fetch;


	$fetch = sub {

		Plugins::BBCSounds::SessionManagement::renewSession(
			sub {
				main::DEBUGLOG && $log->is_debug && $log->debug("fetching: $callurl");

				Slim::Networking::SimpleAsyncHTTP->new(
					sub {
						my $http = shift;
						_parse( $http, $menuType, $menu, $denominator, $passDict );
						if ($cacheIt) { _cacheMenu( $callurl, $menu, 21600); }  # Long term cache if needed
						_renderMenuCodeRefs($menu);
						$callback->( { items => $menu } );
					},

					# Called when no response was received or an error occurred.
					sub {
						$log->warn("error: $_[1]");
						$callback->( [ { name => $_[1], type => 'text' } ] );
					}
				)->get($callurl);
			},

			#could not get a session
			sub {
				$menu = [ { name => 'Failed! - Could not get session' } ];
				$callback->( { items => $menu } );
			}
		);
	};

	#For Personalised Pages, we only retreive from cache if we are futher down the menu tree
	if ( $cacheIt && ($args->{'quantity'} == 1) && ( my $cachemenu = _getCachedMenu($callurl) ) ) {
		main::DEBUGLOG && $log->is_debug && $log->debug("Have cached menu");
		_renderMenuCodeRefs($cachemenu);
		$callback->( { items => $cachemenu } );
	}else {
		main::DEBUGLOG && $log->is_debug && $log->debug("No cache");
		$fetch->();
	}

	main::DEBUGLOG && $log->is_debug && $log->debug("--getPersonalisedPage");
	return;
}


sub getPidDataForMeta {
	my $isLive = shift;
	my $pid = shift;
	my $cb  = shift;
	my $cbError = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug("++getPidDataForMeta");

	my $url = '';

	if ($isLive) {
		$url = "https://rms.api.bbc.co.uk/v2/broadcasts/$pid";
	}else{
		$url = "https://rms.api.bbc.co.uk/v2/programmes/$pid/playable";
	}


	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;
			my $JSON = decode_json ${ $http->contentRef };
			$cb->($JSON);
		},

		# Called when no response was received or an error occurred.
		sub {
			$log->warn("error: $_[1]");
			$cbError->();
		}
	)->get($url);
	main::DEBUGLOG && $log->is_debug && $log->debug("--getPidDataForMeta");
	return;
}


sub getLatestSegmentForNetwork {
	my $network = shift;
	my $cb  = shift;
	my $cbError = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug("++getLatestSegmentForNetwork");

	my $url = "https://rms.api.bbc.co.uk/v2/services/$network/segments/latest?limit=1";


	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;
			my $JSON = decode_json ${ $http->contentRef };
			$cb->($JSON);
		},

		# Called when no response was received or an error occurred.
		sub {
			$log->warn("error: $_[1]");
			$cbError->();
		}
	)->get($url);

	main::DEBUGLOG && $log->is_debug && $log->debug("--getLatestSegmentForNetwork");
	return;
}


sub getSegmentsForPID {
	my $pid = shift;
	my $cb  = shift;
	my $cbError = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug("++getSegmentsForPID");

	my $url = "https://rms.api.bbc.co.uk/v2/versions/$pid/segments";


	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;
			my $JSON = decode_json ${ $http->contentRef };
			$cb->($JSON);
		},

		# Called when no response was received or an error occurred.
		sub {
			$log->warn("error: $_[1]");
			$cbError->();
		}
	)->get($url);

	main::DEBUGLOG && $log->is_debug && $log->debug("--getSegmentForPID");
	return;
}


sub getSubMenu {
	my ( $client, $callback, $args, $passDict ) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++getSubMenu");

	my $menuType = $passDict->{'type'};

	my $menu = [];

	if ( $menuType eq 'categories' ) {
		$menu = [
			{
				name        => 'Browse all Music',
				type        => 'link',
				image => Plugins::BBCSounds::Utilities::IMG_MUSIC,
				url         => \&getPage,
				passthrough => [
					{
						type         => 'categories',
						categorytype => 'music',
						codeRef      => 'getPage'
					}
				],
			},
			{
				name        => 'Browse all Speech',
				type        => 'link',
				image => Plugins::BBCSounds::Utilities::IMG_SPEECH,
				url         => \&getPage,
				passthrough => [
					{
						type         => 'categories',
						categorytype => 'speech',
						codeRef      => 'getPage'
					}
				],
			}
		];
	}elsif ( $menuType eq 'mysounds' ) {
		$menu = [
			{
				name => 'Latest',
				type => 'link',
				image => Plugins::BBCSounds::Utilities::IMG_LATEST,
				url  => \&getPersonalisedPage,
				passthrough =>[ { type => 'latest', codeRef => 'getPersonalisedPage' } ],
			},
			{
				name => 'Bookmarks',
				type => 'link',
				image => Plugins::BBCSounds::Utilities::IMG_BOOKMARK,
				url  => \&getPersonalisedPage,
				passthrough =>[ { type => 'bookmarks', codeRef => 'getPersonalisedPage' } ],
			},
			{
				name        => 'Subscribed',
				type        => 'link',
				image => Plugins::BBCSounds::Utilities::IMG_SUBSCRIBE,
				url         => \&getPersonalisedPage,
				passthrough => [{ type => 'subscribed', codeRef => 'getPersonalisedPage' }],
			},
			{
				name => 'Continue Listening',
				type => 'link',
				image => Plugins::BBCSounds::Utilities::IMG_CONTINUE,
				url  => \&getPersonalisedPage,
				passthrough =>[ { type => 'continue', codeRef => 'getPersonalisedPage' } ],
			}

		];
	}

	$callback->( { items => $menu } );
	main::DEBUGLOG && $log->is_debug && $log->debug("--getSubMenu");
	return;
}


sub initSignin {
	my ( $client, $callback, $args, $passDict ) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++initSignin");
	my $menu = [];

	Plugins::BBCSounds::SessionManagement::signIn(
		sub {

			main::DEBUGLOG && $log->is_debug && $log->debug("Sign In Succeeded");
			$menu = [
				{
					name => 'Sign In Succeeded'
				}
			];
			$callback->( { items => $menu } );
		},
		sub {

			main::DEBUGLOG && $log->is_debug && $log->debug("Sign In Failed");
			$menu = [
				{
					name => 'Sign In Failed'
				}
			];
			$callback->( { items => $menu } );
		}
	);
	main::DEBUGLOG && $log->is_debug && $log->debug("--initSignin");
	return;
}


sub initSignout {
	my ( $client, $callback, $args, $passDict ) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++initSignout");
	my $menu = [];

	Plugins::BBCSounds::SessionManagement::signOut(
		sub {

			main::DEBUGLOG && $log->is_debug && $log->debug("Sign Out Succeeded");
			$menu = [
				{
					name => 'Sign Out Succeeded'
				}
			];
			$callback->( { items => $menu } );
		},
		sub {

			main::DEBUGLOG && $log->is_debug && $log->debug("Sign Out Failed");
			$menu = [
				{
					name => 'Sign Out Failed'
				}
			];
			$callback->( { items => $menu } );
		}
	);
	main::DEBUGLOG && $log->is_debug && $log->debug("--initSignout");
	return;
}


sub _parse {
	my $http        = shift;
	my $optstr      = shift;
	my $menu        = shift;
	my $denominator = shift;
	my $passthrough = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug("++parse");

	if ( $optstr eq 'live' ) {
		_parseLiveStations( $http->contentRef, $menu );
	}elsif (( $optstr eq 'search' )
		|| ( $optstr eq 'searchall' )) {
		my $JSON = decode_json ${ $http->contentRef };
		_parseItems( _getDataNode( $JSON->{data}, 'container_search' ), $menu );
		_parseItems( _getDataNode( $JSON->{data}, 'playable_search' ),  $menu );
	}elsif (( $optstr eq 'tleo' )
		|| ( $optstr eq 'container' )
		|| ( $optstr eq 'latest' )
		|| ( $optstr eq 'bookmarks' )
		|| ( $optstr eq 'subscribed' )
		|| ( $optstr eq 'continue' )
		|| ( $optstr eq 'searchepisodes')
		|| ( $optstr eq 'searchshows' )
		|| ( $optstr eq 'stationfeatured' )) {
		my $JSON = decode_json ${ $http->contentRef };
		_parseItems( $JSON->{data}, $menu );
		_createOffset( $JSON, $passthrough, $menu );
	}elsif ( $optstr eq 'categories' )  {
		my $JSON = decode_json ${ $http->contentRef };
		_parseCategories( $JSON->{data}, $menu );
	}elsif (( $optstr eq 'podcasts' )
		|| ( $optstr eq 'music' )) {
		my $JSON = decode_json ${ $http->contentRef };
		_parseInline( $JSON->{data}, $menu );
	}elsif ( $optstr eq 'childcategories' ) {
		my $JSON = decode_json ${ $http->contentRef };
		_parseChildCategories( $JSON, $menu );
	}elsif ( $optstr eq 'stationlist' ) {
		my $JSON = decode_json ${ $http->contentRef };
		_parseStationlist( _getDataNode( $JSON->{data}, 'promoted_stations' ),$menu );
		_parseStationlist( _getDataNode( $JSON->{data}, 'local_stations' ),$menu );
	}elsif ( $optstr eq 'inlineURN') {
		my $JSON = decode_json ${ $http->contentRef };
		my $node = _getNode( $JSON->{data}, 'container_list' );
		_parseItems($node->{data},$menu );
		_createOffset( $node->{uris}->{pagination}, $passthrough, $menu );
	}elsif ( $optstr eq 'stationsdayschedule' ) {
		my $JSON = decode_json ${ $http->contentRef };
		_parseItems( _getDataNode( $JSON->{data}, 'schedule_items' ), $menu );
	}elsif( $optstr eq 'segments' )  {
		my $JSON = decode_json ${ $http->contentRef };
		_parseTracklist( $JSON->{data}, $passthrough, $menu );
	}else {
		$log->error("Invalid BBC API Parse option");
	}

	main::DEBUGLOG && $log->is_debug && $log->debug("--parse");
	return;
}


sub _getDataNode {
	my $json = shift;
	my $id   = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug("--_getDataNode");

	my $item = [];

	for my $top (@$json) {
		if ( $top->{id} eq $id ) {
			$item = $top->{data};
		}
	}
	main::DEBUGLOG && $log->is_debug && $log->debug("--_getDataNode");
	return $item;
}


sub _getNode {
	my $json = shift;
	my $id   = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug("--_getNode");

	my $item = [];

	for my $top (@$json) {
		if ( $top->{id} eq $id ) {
			return $top;
		}
	}
	main::DEBUGLOG && $log->is_debug && $log->debug("--_getNode");
}


sub _parseItems {
	my $jsonData = shift;
	my $menu     = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_parseItems");
	my $size = scalar @$jsonData;

	$log->info("Number of items : $size ");

	for my $item (@$jsonData) {

		my $isPlayablePref = $prefs->get('playableAsPlaylist');

		if ( $item->{type} eq 'playable_item' ) {
			_parsePlayableItem( $item, $menu, $isPlayablePref );
		}elsif ( $item->{type} eq 'container_item' ) {
			_parseContainerItem( $item, $menu );
		}elsif ( $item->{type} eq 'broadcast_summary' ) {
			_parseBroadcastItem( $item, $menu, $isPlayablePref );
		}
	}
	main::DEBUGLOG && $log->is_debug && $log->debug("--_parseItems");
	return;
}


sub _parseTracklist {
	my $jsonData = shift;
	my $passthrough = shift;
	my $menu     = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_parseTracklist");
	my $size = scalar @$jsonData;

	$log->info("Number of items : $size ");

	for my $item (@$jsonData) {
		my $title = strftime( '%H:%M:%S ', gmtime($item->{offset}->{start}) ) . $item->{titles}->{secondary} . ' - ' . $item->{titles}->{primary};
		push @$menu,
		  {
			name        => $title,
			type        => 'audio',
			url         => 'sounds://_' . $passthrough->{id} . '_' . $passthrough->{pid} . '_' . $item->{offset}->{start},
		  };
	}
	main::DEBUGLOG && $log->is_debug && $log->debug("--_parseTracklist");
	return;
}


sub _parseStationlist {
	my $jsonData = shift;
	my $menu     = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_parseStationlist");
	my $size = scalar @$jsonData;

	for my $item (@$jsonData) {
		my $image = Plugins::BBCSounds::Utilities::createNetworkLogoUrl($item->{network}->{logo_url});
		push @$menu,
		  {
			name        => $item->{network}->{short_title},
			type        => 'link',
			image       => $image,
			url         => '',
			passthrough => [
				{
					type      => 'stationschedule',
					stationid => $item->{id},
					codeRef   => 'getStationMenu',
					networkDetails => $item->{network}
				}
			],
		  };
	}
	main::DEBUGLOG && $log->is_debug && $log->debug("--_parseStationlist");
	return;
}


sub _parsePlayableItem {
	my ($item, $menu, $isPlayable) = @_;

	main::DEBUGLOG && $log->is_debug && $log->debug("++_parsePlayableItem");

	my $title1 = $item->{titles}->{primary};
	my $title2 = $item->{titles}->{secondary};
	if ( defined $title2 ) {
		$title2 = ' - ' . $title2;
	}else {
		$title2 = '';
	}
	my $title3 = $item->{titles}->{tertiary};
	if ( defined $title3 ) {
		$title3 = ' ' . $title3;
	}else {
		$title3 = '';
	}

	my $release = $item->{release}->{label};
	if ( defined $release ) {
		$release = ' : ' . $release;
	}else {
		$release = '';
	}

	my $title = $title1 . $title2 . $title3 . $release;
	my $pid   = _getPidfromSoundsURN( $item->{urn} );

	my $image =Plugins::BBCSounds::PlayManager::createIcon($item->{image_url});

	my $playMenu = [];
	_getPlayableItemMenu($item, $playMenu);

	my $favUrl = '';
	my $type = 'link';

	if ($isPlayable && (defined @$playMenu[0]->{type})) {
		$favUrl = @$playMenu[0]->{url};
		$type = 'playlist';
	}

	main::DEBUGLOG && $log->is_debug && $log->debug("Is Playable : $isPlayable");

	push @$menu,
	  {
		name => $title,
		type => $type,
		favorites_url => $favUrl,
		image => $image,
		items => $playMenu,
		order => 0,
	  };

	main::DEBUGLOG && $log->is_debug && $log->debug("--_parsePlayableItem");
	return;

}


sub _parseBroadcastItem {
	my ($item, $menu, $isPlayable) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_parseBroadcastItem");

	my $title1 = $item->{titles}->{primary};
	my $title2 = $item->{titles}->{secondary};
	my $title3 = $item->{synopses}->{short};

	my $sttim = str2time( $item->{'start'} );
	my $sttime = strftime( '%H:%M ', localtime($sttim) );

	my $title = $sttime . $title1 . ' - ' . $title2;

	my $image =Plugins::BBCSounds::PlayManager::createIcon($item->{image_url});

	my $playMenu = [];
	_getPlayableItemMenu($item, $playMenu);

	my $favUrl = '';
	my $type = 'link';


	if ($isPlayable && (defined @$playMenu[0]->{type})) {
		$favUrl = @$playMenu[0]->{url};
		$type = 'playlist';
	}

	push @$menu,
	  {
		name => $title,
		type => $type,
		image => $image,
		favorites_url => $favUrl,
		items => $playMenu,
		order => 0,
	  };

	main::DEBUGLOG && $log->is_debug && $log->debug("--_parseBroadcastItem");
	return;
}


sub _createOffset {
	my $json        = shift;
	my $passthrough = shift;
	my $menu        = shift;

	main::DEBUGLOG && $log->is_debug && $log->debug("++_createOffset");

	if ( defined $json->{offset} ) {
		my $offset = $json->{offset};
		my $total  = $json->{total};
		my $limit  = $json->{limit};

		if ( ( $offset + $limit ) < $total ) {
			my $nextoffset = $offset + $limit;
			my $nextend    = $nextoffset + $limit;
			if ( $nextend > $total ) { $nextend = $total; }
			my $title ='Next - ' . $nextoffset . ' to ' . $nextend . ' of ' . $total;

			$passthrough->{'offset'} = $nextoffset;

			push @$menu,
			  {
				name        => $title,
				type        => 'link',
				url         => '',
				passthrough => [$passthrough],
			  };

		}
	}
	main::DEBUGLOG && $log->is_debug && $log->debug("--_createOffset");
	return;
}


sub _parseContainerItem {
	my $JSON = shift;
	my $menu    = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_parseContainerItem");

	my $title = $JSON->{titles}->{primary};
	my $desc  = $JSON->{synopses}->{short};

	if ($desc) {
		$title .= ' - ' . $desc;
	}

	my $pid = $JSON->{id};
	my $urn = $JSON->{urn};

	my $image =Plugins::BBCSounds::PlayManager::createIcon($JSON->{image_url});

	my $isFollowed = _isFollowedActivity($JSON->{activities});
	$isFollowed = 0 if (!(defined $isFollowed));

	my $passthrough = [
		{
			type    => 'tleo',
			filter  => 'container=' . $pid,
			offset  => 0,
			codeRef => 'getPage'
		}
	];

	my $favouritesUrl = 'soundslist://_CONTAINER_' . $pid;

	#check that the item is a normal container not a tag
	if ( $urn =~ /:tag:/) {
		$passthrough = [
			{
				type    => 'inlineURN',
				urn  => $urn,
				offset  => 0,
				codeRef => 'getPage'
			}
		];
		$favouritesUrl = '';

	} elsif ( $urn =~ /:category:/) {
		$passthrough = [
			{
				type    => 'inlineURN',
				urn  => $urn,
				offset  => 0,
				codeRef => 'getPage'
			}
		];
		$favouritesUrl = '';
	}

	push @$menu,
	  {
		name        => $title,
		type        => 'link',
		image        => $image,
		url         => '',
		favorites_url => $favouritesUrl,
		favorites_type	=> 'link',
		playlist => $favouritesUrl,
		itemActions => {
			info => {
				command     => ['sounds', 'subscribeUnsubscribe'],
				fixedParams => { urn => $urn, isSubscribed => $isFollowed },
			},
		},
		order 		=> 0,
		passthrough => $passthrough,
	  };

	main::DEBUGLOG && $log->is_debug && $log->debug("--_parseContainerItem");
	return;
}


sub _parseCategories {
	my $jsonData = shift;
	my $menu     = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_parseCategories");

	my $size = scalar @$jsonData;

	$log->info("Number of cats : $size ");

	for my $cat (@$jsonData) {
		my $title = $cat->{titles}->{primary};
		my $image =Plugins::BBCSounds::PlayManager::createIcon($cat->{image_url});
		push @$menu,
		  {
			name        => $title,
			type        => 'link',
			image        => $image,
			url         => '',
			passthrough => [
				{
					type     => 'childcategories',
					category => $cat->{id},
					offset   => 0,
					codeRef  => 'getPage'
				}
			],
		  };
	}

	main::DEBUGLOG && $log->is_debug && $log->debug("--_parseCategories");
	return;
}


sub _parseInline {
	my $jsonData = shift;
	my $menu     = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_parseInline");

	for my $podline (@$jsonData) {
		_InlineMenuCreator($podline, $menu);
	}

	main::DEBUGLOG && $log->is_debug && $log->debug("--_parseInline");
	return;
}


sub _InlineMenuCreator {
	my $menuInline = shift;
	my $menu     = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_InlineMenuCreator");
	if ($menuInline->{type} eq 'inline_display_module') {
		if ($menuInline->{uris}) {
			push @$menu,
			  {
				name        =>  $menuInline->{title},
				type        => 'link',
				url         => '',
				passthrough => [
					{
						type     => 'inlineURN',
						urn => $menuInline->{controls}->{navigation}->{target}->{urn},
						offset   => 0,
						codeRef  => 'getPage'
					}
				]
			  };
		} else {

			#we can place it inline
			my $submenu = [];
			_parseItems( $menuInline->{data}, $submenu );


			push @$menu,{
				name  =>  $menuInline->{title},
				type  => 'link',
				items => $submenu,

			};
		}
	}
	main::DEBUGLOG && $log->is_debug && $log->debug("--_InlineMenuCreator");
	return;
}


sub _parseChildCategories {
	my $json = shift;
	my $menu = shift;

	main::DEBUGLOG && $log->is_debug && $log->debug("++_parseChildCategories");

	my $catId    = $json->{id};
	my $catTitle = $json->{title};

	my $children = $json->{child_categories};

	for my $cat (@$children) {
		my $title = $cat->{title};
		push @$menu,
		  {
			name        => $catTitle . ' - ' . $title,
			type        => 'link',
			url         => '',
			passthrough => [
				{
					type     => 'container',
					category => $cat->{id},
					offset   => 0,
					codeRef  => 'getPage'
				}
			],
		  };
	}
	push @$menu,
	  {
		name        => 'All ' . $catTitle,
		type        => 'link',
		url         => '',
		passthrough => [
			{
				type     => 'container',
				category => $catId,
				offset   => 0,
				codeRef  => 'getPage'
			}
		],
	  };

	main::DEBUGLOG && $log->is_debug && $log->debug("--_parseChildCategories");
	return;
}


sub _getPidfromSoundsURN {
	my $urn = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_getPidfromSoundsURN");

	main::DEBUGLOG && $log->is_debug && $log->debug("urn to create pid : $urn");
	my @pid = split /:/x, $urn;
	my $pid = pop(@pid);

	main::DEBUGLOG && $log->is_debug && $log->debug("--_getPidfromSoundsURN - $pid");
	return $pid;
}


sub _parseTopInlineMenu {
	my $topJSON = shift;
	my $moduleName = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_parseTopInlineMenu");

	my $jsonData = $topJSON->{data};

	for my $module (@$jsonData) {
		if ($module->{id} eq $moduleName) {
			main::DEBUGLOG && $log->is_debug && $log->debug("--_parseTopInlineMenu");
			return $module;
		}
	}
	main::INFOLOG && $log->is_info && $log->info('Failed to find Top menu module ' . $moduleName);
	main::DEBUGLOG && $log->is_debug && $log->debug("--_parseTopInlineMenu");
	return;
}


sub _getPlayableItemMenu {
	my $JSON = shift;
	my $menu = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_getPlayableItemMenu");
	my $item = $JSON;
	if (defined $JSON->{'playable_item'}) {
		$item = $JSON->{'playable_item'};
	}

	my $urn        = $item->{urn};
	my $pid        = _getPidfromSoundsURN( $item->{urn} );
	my $id         = $item->{id};
	my $progress   = $item->{progress};
	my $timeOffset = 0;
	my $playLabel  = '';
	if ( defined $progress ) {
		$timeOffset = $progress->{value};
		$playLabel  = ' - ' . $progress->{label};
	}

	my $soundsUrl = 'sounds://_' . $id . '_' . $pid . '_0';
	my $soundsResumeUrl = 'sounds://_' . $id . '_' . $pid . '_' . $timeOffset;

	my $booktype = 'Bookmark';
	my $bookCodeRef = 'createActivityWrapper';
	if (_isFavouritedActivity($item->{activities})) {
		$booktype = 'Remove bookmark';
		$bookCodeRef = 'deleteActivityWrapper';
	}
	push @$menu,
	  {
		name        => $booktype,
		type        => 'link',
		order 		=> 4,
		url         => '',
		image       => Plugins::BBCSounds::Utilities::IMG_BOOKMARK,
		passthrough => [
			{
				activitytype => 'bookmark',
				urn          => $urn,
				codeRef      => $bookCodeRef
			}
		],
	  };

	if ( defined $item->{container}->{id} ) {
		my $subtype = 'Subscribe';
		my $subCodeRef = 'createActivityWrapper';
		if (_isFollowedActivity($item->{container}->{activities})) {
			$subtype = 'Unsubscribe';
			$subCodeRef = 'deleteActivityWrapper';
		}
		push @$menu,
		  {
			name        => $subtype,
			type        => 'link',
			order 		=> 5,
			url         => '',
			image       => Plugins::BBCSounds::Utilities::IMG_SUBSCRIBE,
			passthrough => [
				{
					activitytype => 'subscribe',
					urn          => $item->{container}->{urn},
					codeRef      => $subCodeRef
				}
			],
		  };
		push @$menu, {
			name        => 'All Episodes',
			type        => 'link',
			order 		=> 3,
			url         => '',
			image       => Plugins::BBCSounds::Utilities::IMG_EPISODES,
			passthrough => [
				{
					type    => 'tleo',
					filter  => 'container=' . $item->{container}->{id},
					offset  => 0,
					codeRef => 'getPage'
				}
			],

		};
	}

	push @$menu, {
		name        => 'Tracklist',
		type        => 'link',
		order 		=> 6,
		url         => '',
		image       => Plugins::BBCSounds::Utilities::IMG_TRACKS,
		passthrough => [
			{
				type    => 'segments',
				id => $id,
				pid => $pid,
				offset  => 0,
				codeRef => 'getPage'
			}
		],

	};

	if (defined $item->{synopses}) {
		my $syn = '';
		if (defined $item->{synopses}->{long}) {
			$syn = $item->{synopses}->{long};
		} elsif (defined $item->{synopses}->{medium}) {
			$syn = $item->{synopses}->{medium};
		} elsif (defined $item->{synopses}->{short}) {
			$syn = $item->{synopses}->{short};
		}

		push @$menu,
		  {
			name => 'Synopsis',
			order => 7,
			image => Plugins::BBCSounds::Utilities::IMG_SYNOPSIS,
			items => [
				{
					name        => $syn,
					type        => 'textarea'
				},
			]
		  };
	}


	if (defined $item->{availability}) {
		push @$menu,
		  {
			name => 'Play',
			url  => $soundsUrl,
			image      => Plugins::BBCSounds::Utilities::IMG_PLAY,
			icon       => Plugins::BBCSounds::Utilities::IMG_PLAY,
			type => 'audio',
			order => 1,
			passthrough => [ {} ],
			on_select   => 'play',
		  };

		if ($timeOffset) {
			push @$menu,
			  {
				name => 'Resume' . $playLabel,
				url  => $soundsResumeUrl,
				image      => Plugins::BBCSounds::Utilities::IMG_PLAY,
				icon       => Plugins::BBCSounds::Utilities::IMG_PLAY,
				type => 'audio',
				order => 2,
				passthrough => [ {} ],
				on_select   => 'play',
			  };
		}

	} else {

		#if not available try and construct a live rewind url
		if (my $startTime = $item->{start}) {
			if ((str2time($startTime) > (time() - 14400)) && (str2time($startTime) < time())) {

				# less then 4 hours ago, constuct a live rewind url
				$soundsUrl = 'sounds://_REWIND_' .  str2time($startTime) . '_LIVE_' . $item->{service_id};
				push @$menu,
				  {
					name => 'Play (live rewind)',
					url  => $soundsUrl,
					image      => Plugins::BBCSounds::Utilities::IMG_PLAY,
					icon       => Plugins::BBCSounds::Utilities::IMG_PLAY,
					type => 'audio',
					order => 1,
					passthrough => [ {} ],
					on_select   => 'play',
				  };
			} else {
				push @$menu,
				  {
					name => 'Not Currently Available',
					order 		=> 1,
				  };
			}
		} else {
			push @$menu,
			  {
				name => 'Not Currently Available',
				order 		=> 1,
			  };
		}
	}

	@$menu = sort { $a->{order} <=> $b->{order} } @$menu;

	main::DEBUGLOG && $log->is_debug && $log->debug("--_getPlayableItemMenu");
	return;
}


sub _getCachedMenu {
	my $url = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_getCachedMenu");

	my $cacheKey = 'BS:' . md5_hex($url);

	if ( my $cachedMenu = $cache->get($cacheKey) ) {
		my $menu = ${$cachedMenu};
		main::DEBUGLOG && $log->is_debug && $log->debug("--_getCachedMenu got cached menu");
		return $menu;
	}else {
		main::DEBUGLOG && $log->is_debug && $log->debug("--_getCachedMenu no cache");
		return;
	}
}


sub _cacheMenu {
	my $url  = shift;
	my $menu = shift;
	my $seconds = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_cacheMenu");
	my $cacheKey = 'BS:' . md5_hex($url);

	$cache->set( $cacheKey, \$menu, $seconds );

	main::DEBUGLOG && $log->is_debug && $log->debug("--_cacheMenu");
	return;
}


sub _removeCacheMenu {
	my $url  = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_removeCacheMenu");
	my $cacheKey = 'BS:' . md5_hex($url);

	$cache->remove($cacheKey);

	main::DEBUGLOG && $log->is_debug && $log->debug("--_removeCacheMenu");
	return;
}


sub _isFollowedActivity {
	my $activities = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_isFollowedActivity");
	if (defined $activities) {
		for my $activity (@$activities) {
			if  ($activity->{type} eq 'follow_activity') {
				if ($activity->{action} eq 'followed') {
					return 1;
				}
			}
		}
	}
	main::DEBUGLOG && $log->is_debug && $log->debug("--_isFollowedActivity");
	return;
}


sub _isFavouritedActivity {
	my $activities = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_isFavouritedActivity");
	if (defined $activities) {
		for my $activity (@$activities) {
			if  ($activity->{type} eq 'favourite_activity') {
				if ($activity->{action} eq 'favourited') {
					return 1;
				}
			}
		}
	}
	main::DEBUGLOG && $log->is_debug && $log->debug("--_isFavouritedActivity ");
	return;
}


sub _renderMenuCodeRefs {
	my $menu = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_renderMenuCodeRefs");

	my %subItems = (
		'getPage' => \&getPage,
		'getSubMenu' => \&getSubMenu,
		'getStationMenu' => \&getStationMenu,
		'createActivityWrapper' => \&createActivityWrapper,
		'deleteActivityWrapper' => \&deleteActivityWrapper,
		'getPersonalisedPage' => \&getPersonalisedPage,
		'recentSearches' => \&recentSearches
	);

	for my $menuItem (@$menu) {
		my $codeRef = $menuItem->{passthrough}[0]->{'codeRef'};
		if ( defined $codeRef ) {
			$menuItem->{'url'} = $subItems{$codeRef};
		}
		if (defined $menuItem->{'items'}) {
			_renderMenuCodeRefs($menuItem->{'items'});
		}
	}

	main::DEBUGLOG && $log->is_debug && $log->debug("--_renderMenuCodeRefs");
	return;
}


sub getNetworkSchedule {
	my $network = shift;
	my $cbY = shift;
	my $cbN = shift;
	my $isPrevious = shift;

	main::DEBUGLOG && $log->is_debug && $log->debug("++getNetworkSchedule");
	my $callurl = 'https://rms.api.bbc.co.uk/v2/broadcasts/poll/' . $network;

	if ($isPrevious) {
		$callurl = 'https://rms.api.bbc.co.uk/v2/broadcasts/latest?service=' . $network . '&previous=240';
	}


	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;
			my $schedule = decode_json ${ $http->contentRef };
			$cbY->($schedule);
		},
		sub {
			# Called when no response was received or an error occurred.
			$log->warn("error: $_[1]");
			$cbN->();
		}
	)->get($callurl);

	main::DEBUGLOG && $log->is_debug && $log->debug("--getNetworkSchedule");
	return;
}


sub _globalSearchItems {
	my ($client, $query) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_globalSearchItems");

	my @items = (
		{
			name  => 'Search Shows',
			url   => \&getPage,
			passthrough => [ { type => 'searchshows', codeRef => 'getPage', query => $query } ]
		},
		{
			name  => 'Search Episodes',
			url   => \&getPage,
			passthrough => [ { type => 'searchepisodes', codeRef => 'getPage',query => $query } ]
		},
		{
			name  => 'Search All',
			url   => \&getPage,
			passthrough => [ { type => 'searchall', codeRef => 'getPage', query => $query } ]
		}
	);

	#async call to renew session, as this could be the top level
	Plugins::BBCSounds::SessionManagement::renewSession(
		sub {
			main::INFOLOG && $log->is_info && $log->info("Session available for global search");
		},
		sub {
			$log->warn("Failed to renew session on global search");
		}
	);

	main::DEBUGLOG && $log->is_debug && $log->debug("--_globalSearchItems");
	return \@items;
}


sub recentSearches {
	my ($client, $cb, $params) = @_;

	my $items = [];

	my $i = 0;
	for my $recent ( @{ $prefs->get('sounds_recent_search') || [] } ) {
		unshift @$items,
		  {
			name  => $recent,
			type  => 'link',
			url   => \&getPage,
			itemActions => {
				info => {
					command     => ['sounds', 'recentsearches'],
					fixedParams => { deleteMenu => $i++ },
				},
			},
			passthrough => [
				{
					type => 'search',
					query => $recent,
					recent => 1,
					codeRef => 'getPage'
				}
			],
		  };
	}

	unshift @$items,
	  {
		name  => 'New Search',
		type  => 'search',
		url   => \&getPage,
		passthrough => [ { type => 'search' }],
	  };

	$cb->({ items => $items });
}


sub soundsInfoIntegration {
	my ( $client, $url, $track, $remoteMeta ) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++soundsInfoIntegration");

	my $items = [];
	if (Plugins::BBCSounds::Utilities::isSoundsURL($url)) {
		if (!(Plugins::BBCSounds::ProtocolHandler::isLive(undef,$url) || Plugins::BBCSounds::ProtocolHandler::isRewind(undef, $url))) {


			push @$items,
			  {
				name => 'Tracklist',
				type        => 'link',
				url         => \&getPage,
				passthrough => [
					{
						type    => 'segments',
						id => Plugins::BBCSounds::ProtocolHandler::getId(undef,$url),
						offset  => 0,
						codeRef => 'getPage'
					}
				],
			  };

			push @$items,
			  {
				name        => 'Bookmark Episode',
				type        => 'link',
				order 		=> 3,
				url         => \&Plugins::BBCSounds::ActivityManagement::createActivityWrapper,
				passthrough => [
					{
						activitytype => 'bookmark',
						urn          => 'urn:bbc:radio:episode:' . Plugins::BBCSounds::ProtocolHandler::getPid(undef, $url),
						codeRef      => 'createActivityWrapper'
					}
				],
			  };

		} elsif (Plugins::BBCSounds::ProtocolHandler::isLive(undef,$url))  {

			push @$items,
			  {
				name => 'Station Schedule',
				type        => 'link',
				url         => \&getPage,
				passthrough => [
					{
						type         => 'stationsdayschedule',
						stationid    => Plugins::BBCSounds::ProtocolHandler::_getStationID($url),
						scheduledate => strftime( '%Y-%m-%d', localtime(time()) ),
						codeRef      => 'getPage'
					}
				],
			  };

		}

		my $song = Slim::Player::Source::playingSong($client);

		#get the meta data
		if ((my $meta = $song->pluginData('meta')) && (Slim::Utils::PluginManager->isEnabled('Plugins::Spotty::Plugin'))) {
			if (!($meta->{spotify} eq '')) {
				push @$items,
				  {
					name => 'BBC Sounds Now Playing On Spotify',
					type => 'audio',
					url  =>  $meta->{spotify},
					on_select   => 'play'
				  };

			}
		}
	}
	main::DEBUGLOG && $log->is_debug && $log->debug("--soundsInfoIntegration");
	return \@$items;
}


sub _subscribeCLI {
	my $request = shift;
	my $client = $request->client;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_subscribeCLI");

	# check this is the correct command.
	if ($request->isNotCommand([['sounds'], ['subscribeUnsubscribe']])) {
		$request->setStatusBadDispatch();
		return;
	}

	my $items = [];

	my $urn = $request->getParam('urn');

	if (defined $request->getParam('isSubscribed')) {
		my $isSubscribed = $request->getParam('isSubscribed');

		if ($isSubscribed) {
			push @$items,
			  {
				text => 'Unsubscribe',
				actions => {
					go => {
						player => 0,
						cmd    => ['sounds', 'subscribeUnsubscribe' ],
						params => {
							urn => $urn,
							act => 'unfollow'
						},
					}
				},
				nextWindow => 'parent',
			  };
		} else {
			push @$items,
			  {
				text => 'Subcribe',
				actions => {
					go => {
						player => 0,
						cmd    => ['sounds', 'subscribeUnsubscribe' ],
						params => {
							urn => $urn,
							act => 'follow'
						},
					}
				},
				nextWindow => 'parent',
			  };

		}
		$request->addResult('offset', 0);
		$request->addResult('count', scalar @$items);
		$request->addResult('item_loop', $items);
		$request->setStatusDone;

	} else {
		my $act = $request->getParam('act');
		if ($act eq 'follow') {
			Plugins::BBCSounds::ActivityManagement::createActivity(
				sub {
					my $result = shift;
					$request->addResult($result);
					$client->showBriefly(
						{
							line => [ $result, 'BBC Sounds' ],
						}
					);

					$request->setStatusDone();
				},
				{
					activitytype => 'subscribe',
					urn          => $urn
				}
			);
		} elsif ($act eq 'unfollow') {
			Plugins::BBCSounds::ActivityManagement::deleteActivity(
				sub {
					my $result = shift;
					$request->addResult($result);
					$client->showBriefly(
						{
							line => [ $result, 'BBC Sounds' ],
						}
					);

					$request->setStatusDone();
				},
				{
					activitytype => 'subscribe',
					urn          => $urn
				}
			);
		} else {
			$log->error("Unknown subscibe menu action");
			$request->setStatusDone;
		}
	}

	main::DEBUGLOG && $log->is_debug && $log->debug("--_subscribeCLI");
	return;
}

#This came from Mherger for managing the search history
sub _recentSearchesCLI {
	my $request = shift;
	my $client = $request->client;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_recentSearchesCLI");

	# check this is the correct command.
	if ($request->isNotCommand([['sounds'], ['recentsearches']])) {
		$request->setStatusBadDispatch();
		return;
	}

	my $list = $prefs->get('sounds_recent_search') || [];
	my $del = $request->getParam('deleteMenu') || $request->getParam('delete') || 0;

	if (!scalar @$list || $del >= scalar @$list) {
		$log->error('Search item to delete is outside the history list!');
		$request->setStatusBadParams();
		return;
	}

	my $items = [];

	if (defined $request->getParam('deleteMenu')) {
		push @$items,
		  {
			text => cstring($client, 'DELETE') . cstring($client, 'COLON') . ' "' . ($list->[$del] || '') . '"',
			actions => {
				go => {
					player => 0,
					cmd    => ['sounds', 'recentsearches' ],
					params => {
						delete => $del
					},
				},
			},
			nextWindow => 'parent',
		  },
		  {
			text => 'Clear search history',
			actions => {
				go => {
					player => 0,
					cmd    => ['sounds', 'recentsearches' ],
					params => {
						deleteAll => 1
					},
				}
			},
			nextWindow => 'grandParent',
		  };

		$request->addResult('offset', 0);
		$request->addResult('count', scalar @$items);
		$request->addResult('item_loop', $items);
	}elsif ($request->getParam('deleteAll')) {
		$prefs->set( 'sounds_recent_search', [] );
	}elsif (defined $request->getParam('delete')) {
		splice(@$list, $del, 1);
		$prefs->set( 'sounds_recent_search', $list );
	}

	$request->setStatusDone;
	main::DEBUGLOG && $log->is_debug && $log->debug("--_recentSearchesCLI");
	return;
}


sub buttonBookmark {
	my $request = shift;
	my $client  = $request->client();
	main::DEBUGLOG && $log->is_debug && $log->debug("++buttonBookmark");

	return unless defined $client;

	my $song = $client->playingSong() || return;

	# ignore if user is not using Sounds
	my $url = $song->currentTrack()->url;
	return unless Plugins::BBCSounds::Utilities::isSoundsURL($url);

	my $urn = $request->getParam('_urn');

	main::INFOLOG && $log->is_info && $log->info("Button Bookmarking to $urn");

	Plugins::BBCSounds::ActivityManagement::createActivity(
		sub {
			my $result = shift;
			$request->addResult($result);
			$client->showBriefly(
				{
					line => [ $result, 'BBC Sounds' ],
				}
			);
			$request->setStatusDone();
		},
		{
			activitytype => 'bookmark',
			urn          => $urn
		}
	);

	$request->setStatusProcessing();
	main::DEBUGLOG && $log->is_debug && $log->debug("++buttonBookmark");
}


sub buttonSubscribe {
	my $request = shift;
	my $client  = $request->client();
	main::DEBUGLOG && $log->is_debug && $log->debug("++buttonSubscribe");

	return unless defined $client;

	my $song = $client->playingSong() || return;

	# ignore if user is not using Sounds
	my $url = $song->currentTrack()->url;
	return unless Plugins::BBCSounds::Utilities::isSoundsURL($url);

	my $urn = $request->getParam('_urn');

	main::INFOLOG && $log->is_info && $log->info("Button Subscribing to $urn");

	Plugins::BBCSounds::ActivityManagement::createActivity(
		sub {
			my $result = shift;
			$request->addResult($result);
			$client->showBriefly(
				{
					line => [ $result, 'BBC Sounds' ],
				}
			);

			$request->setStatusDone();
		},
		{
			activitytype => 'subscribe',
			urn          => $urn
		}
	);

	$request->setStatusProcessing();
	main::DEBUGLOG && $log->is_debug && $log->debug("--buttonSubscribe");
}


sub createActivityWrapper {
	my ( $client, $callback, $args, $passDict ) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++createActivityWrapper");

	my $menu = [];
	Plugins::BBCSounds::ActivityManagement::createActivity(
		sub {
			my $resp = shift;
			push @$menu,
			  {
				name => $resp,
				type => 'text'
			  };
			$callback->({ items => $menu });
		},
		$passDict
	);

	main::DEBUGLOG && $log->is_debug && $log->debug("--createActivityWrapper");
	return;
}


sub deleteActivityWrapper {
	my ( $client, $callback, $args, $passDict ) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++deleteActivityWrapper");

	my $menu = [];
	Plugins::BBCSounds::ActivityManagement::deleteActivity(
		sub {
			my $resp = shift;
			push @$menu,
			  {
				name => $resp,
				type => 'text'
			  };
			$callback->({ items => $menu });
		},
		$passDict
	);

	main::DEBUGLOG && $log->is_debug && $log->debug("--deleteActivityWrapper");
	return;
}


1;
