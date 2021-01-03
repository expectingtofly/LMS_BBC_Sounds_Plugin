package Plugins::BBCSounds::BBCSoundsFeeder;

# Copyright (C) 2020 mcleanexpectingtofly
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
			func  => \&spottyInfoIntegration,
		)
	);

	Slim::Menu::TrackInfo->registerInfoProvider(
		bbcsounds => (
			after => 'top',
			func  => \&tracklistInfoIntegration,
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
	_removeCacheMenu('toplevel'); #force remove
}


sub toplevel {
	my ( $client, $callback, $args ) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++toplevel");

	my $menu = [];

	#Obtain the variable editorial content title

	my $fetch;
	my $callurl = 'https://rms.api.bbc.co.uk/v2/collections/p07fz59r/container';

	$fetch = sub {
		my $editorialTitle = "Our Daily Picks";
		$menu = [
			{
				name => 'Unmissable Sounds',
				type => 'link',
				url  => '',
				passthrough =>[ { type => 'editorial', codeRef => 'getPage' } ],
				order => 4,
			},
			{
				name        => 'Music Mixes',
				type        => 'link',
				url         => '',
				passthrough => [ { type => 'mixes', codeRef => 'getSubMenu' } ],
				order       => 6,
			},
			{
				name => 'My Sounds',
				type => 'link',
				url  => '',
				passthrough =>[ { type => 'mysounds', codeRef => 'getSubMenu' } ],
				order => 2,
			},
			{
				name        => 'Recommended For You',
				type        => 'link',
				url         => '',
				passthrough => [{ type => 'recommended', codeRef => 'getPersonalisedPage' }],
				order => 7,
			},
			{
				name => 'Stations & Schedules',
				type => 'link',
				url  => '',
				passthrough =>[ { type => 'stationlist', codeRef => 'getPage' } ],
				order => 3,
			},
			{
				name => 'Browse Categories',
				type => 'link',
				url  => '',
				passthrough =>[ { type => 'categories', codeRef => 'getSubMenu' } ],
				order => 8,
			}

		];

		if (Plugins::BBCSounds::Utilities::hasRecentSearches()) {
			push @$menu,{

				name        => 'Search',
				type        => 'link',
				url         => '',
				passthrough => [ { codeRef => 'recentSearches' } ],
				order       => 1,
			};

		} else {
			push @$menu,{

				name        => 'Search',
				type        => 'search',
				url         => '',
				passthrough => [ { type => 'search', codeRef => 'getPage' } ],
				order       => 1,

			};
		}

		main::DEBUGLOG && $log->is_debug && $log->debug("fetching: $callurl");

		Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				my $http = shift;
				$editorialTitle = _parseEditorialTitle( $http->contentRef );
				push @$menu,
				  {
					name => $editorialTitle,
					type => 'link',
					url  => '',
					passthrough =>[ { type => 'daily', codeRef => 'getPage' } ],
					order => 5,
				  };
				@$menu = sort { $a->{order} <=> $b->{order} } @$menu;
				_cacheMenu( 'toplevel', $menu, 2400 );
				_renderMenuCodeRefs($menu);
				$callback->($menu);
			},

			# Called when no response was received or an error occurred.
			sub {
				$log->warn("error: $_[1]");
				push @$menu,
				  {
					name => $editorialTitle,
					type => 'link',
					url  => '',
					passthrough =>[ { type => 'daily', codeRef => 'getPage' } ],
					order => 4,
				  };

				#sort the list by order
				@$menu = sort { $a->{order} <=> $b->{order} } @$menu;
				_cacheMenu( 'toplevel', $menu, 600 );
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
							name =>'Not Signed In!  Please sign in to your BBC Account in preferences'
						}
					];
					$callback->( { items => $menu } );
				}
			);
		}else {
			$menu = [
				{
					name =>'Not Signed In!  Please sign in to your BBC Account in preferences'
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
	}elsif ( $menuType eq 'editorial' ) {
		$callurl ='https://rms.api.bbc.co.uk/v2/experience/inline/listen/sign-in';
	}elsif ( $menuType eq 'daily' ) {
		$callurl ='https://rms.api.bbc.co.uk/v2/collections/p07fz59r/members/playable?experience=domestic';
	}elsif ( $menuType eq 'tleo' ) {
		$callurl ='https://rms.api.bbc.co.uk/v2/my/programmes/playable?'. $passDict->{'filter'} . '&offset='. $passDict->{'offset'};
		$denominator = "";
	}elsif ( $menuType eq 'container' ) {
		$callurl ='https://rms.api.bbc.co.uk/v2/programmes/playable?category=' . $passDict->{'category'} . '&tleoDistinct=true&offset='. $passDict->{'offset'};
		$denominator = $passDict->{'category'};
	}elsif ( $menuType eq 'search' ) {
		my $searchstr = '';
		if ($args->{'recent'} ) {
			$searchstr = $passDict->{'query'};
		} else {
			$searchstr = $args->{'search'};
		}		
		$callurl ='https://rms.api.bbc.co.uk/v2/experience/inline/search?q='. URI::Escape::uri_escape_utf8( $searchstr );
		$cacheIt = 0;
		Plugins::BBCSounds::Utilities::addRecentSearch($searchstr);
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
	}elsif ( $menuType eq 'mixes' ) {
		$callurl ='https://rms.api.bbc.co.uk/v2/tagged/'. $passDict->{'tag'}. '/playable?experience=domestic';
	}elsif ( $menuType eq 'categories' ) {
		$callurl = 'https://rms.api.bbc.co.uk/v2/categories/container?kind='. $passDict->{'categorytype'};
	}elsif ( $menuType eq 'childcategories' ) {
		$callurl ='https://rms.api.bbc.co.uk/v2/categories/' . $passDict->{'category'};
	}elsif ( $menuType eq 'stationsdayschedule' ) {
		$callurl ='https://rms.api.bbc.co.uk/v2/experience/inline/schedules/'. $passDict->{'stationid'} . '/'. $passDict->{'scheduledate'};
	}elsif ( $menuType eq 'segments' ) {
		$callurl = 'https://rms.api.bbc.co.uk/v2/versions/' . $passDict->{'id'} . '/segments';
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

	my $menu      = [
		{
			name        => $NetworkDetails->{short_title} . ' LIVE',
			type        => 'audio',
			icon        =>  Plugins::BBCSounds::Utilities::createNetworkLogoUrl($NetworkDetails->{logo_url}),
			url         => 'sounds://_LIVE_'. $stationid,
			on_select   => 'play'
		}
	];

	for ( my $i = 0 ; $i < 30 ; $i++ ) {
		my $d = '';
		my $epoch = $now - ( 86400 * $i );
		if ( $i == 0 ) {
			$d = 'Today';
		}elsif ( $i == 1 ) {
			$d = 'Yesterday (' . strftime( '%A', localtime($epoch) ) . ')';
		}else {
			$d = strftime( '%A %d/%m/%Y', localtime($epoch) );
		}

		my $scheduledate = strftime( '%Y-%m-%d', localtime($epoch) );

		push @$menu,
		  {
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

	}
	$callback->( { items => $menu } );
	main::DEBUGLOG && $log->is_debug && $log->debug("--getStationMenu");
	return;
}


sub getPersonalisedPage {
	my ( $client, $callback, $args, $passDict ) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++getPersonalisedPage");

	my $menuType = $passDict->{'type'};
	my $callurl  = "";

	if ( $menuType eq 'latest' ) {
		$callurl ='https://rms.api.bbc.co.uk/v2/my/programmes/follows/playable';
	}elsif ( $menuType eq 'subscribed' ) {
		$callurl = 'https://rms.api.bbc.co.uk/v2/my/programmes/follows';
	}elsif ( $menuType eq 'bookmarks' ) {
		$callurl ='https://rms.api.bbc.co.uk/v2/my/programmes/favourites/playable';
	}elsif ( $menuType eq 'recommended' ) {
		$callurl ='https://rms.api.bbc.co.uk/v2/my/programmes/recommendations/playable';
	}elsif ( $menuType eq 'continue' ) {
		$callurl = 'https://rms.api.bbc.co.uk/v2/my/programmes/plays/playable';
	}

	my $menu        = [];
	my $denominator = '';

	Plugins::BBCSounds::SessionManagement::renewSession(
		sub {
			main::DEBUGLOG && $log->is_debug && $log->debug("fetching: $callurl");

			Slim::Networking::SimpleAsyncHTTP->new(
				sub {
					my $http = shift;
					_parse( $http, $menuType, $menu, $denominator, $passDict );
					_renderMenuCodeRefs($menu);
					$callback->( { items => $menu } );
				},
				sub {
					# Called when no response was received or an error occurred.

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
				url  => \&getPersonalisedPage,
				passthrough =>[ { type => 'latest', codeRef => 'getPersonalisedPage' } ],
			},
			{
				name => 'Bookmarks',
				type => 'link',
				url  => \&getPersonalisedPage,
				passthrough =>[ { type => 'bookmarks', codeRef => 'getPersonalisedPage' } ],
			},
			{
				name        => 'Subscribed',
				type        => 'link',
				url         => \&getPersonalisedPage,
				passthrough => [{ type => 'subscribed', codeRef => 'getPersonalisedPage' }],
			},
			{
				name => 'Continue Listening',
				type => 'link',
				url  => \&getPersonalisedPage,
				passthrough =>[ { type => 'continue', codeRef => 'getPersonalisedPage' } ],
			}

		];
	}elsif ( $menuType eq 'mixes' ) {
		$menu = [
			{
				name        => 'Fresh New Music',
				type        => 'link',
				url         => \&getPage,
				passthrough => [
					{
						type    => 'mixes',
						tag     => 'fresh_new_music',
						codeRef => 'getPage'
					}
				],
			},
			{
				name => 'Music to Chill to',
				type => 'link',
				url  => \&getPage,
				passthrough =>[ { type => 'mixes', tag => 'chill', codeRef => 'getPage' } ],
			},
			{
				name        => 'Dance Music',
				type        => 'link',
				url         => \&getPage,
				passthrough => [
					{
						type    => 'mixes',
						tag     => 'dance',
						page    => '1',
						codeRef => 'getPage'
					}
				],
			},
			{
				name        => 'Feel Good Tunes',
				type        => 'link',
				url         => \&getPage,
				passthrough => [
					{
						type    => 'mixes',
						tag     => 'feel_good_tunes',
						page    => '1',
						codeRef => 'getPage'
					}
				],
			},
			{
				name        => 'Music to Focus to',
				type        => 'link',
				url         => \&getPage,
				passthrough => [
					{
						type    => 'mixes',
						tag     => 'focus',
						page    => '1',
						codeRef => 'getPage'
					}
				],
			},
			{
				name        => 'Greatest Hits',
				type        => 'link',
				url         => \&getPage,
				passthrough => [
					{
						type    => 'mixes',
						tag     => 'greatest_hits',
						page    => '1',
						codeRef => 'getPage'
					}
				],
			},
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
	}elsif ( $optstr eq 'editorial' ) {
		my $JSON = decode_json ${ $http->contentRef };
		_parseItems( _getDataNode( $JSON->{data}, 'priority_brands' ), $menu );
	}elsif (( $optstr eq 'search' )
		|| ( $optstr eq 'searchall' )) {
		my $JSON = decode_json ${ $http->contentRef };
		_parseItems( _getDataNode( $JSON->{data}, 'container_search' ), $menu );
		_parseItems( _getDataNode( $JSON->{data}, 'playable_search' ),  $menu );
	}elsif ( $optstr eq 'mixes' ) {
		my $JSON = decode_json ${ $http->contentRef };
		_parseItems( $JSON->{data}, $menu );
	}elsif (( $optstr eq 'tleo' )
		|| ( $optstr eq 'container' )
		|| ( $optstr eq 'latest' )
		|| ( $optstr eq 'bookmarks' )
		|| ( $optstr eq 'daily' )
		|| ( $optstr eq 'subscribed' )
		|| ( $optstr eq 'recommended' )
		|| ( $optstr eq 'continue' )
		|| ( $optstr eq 'searchepisodes')
		|| ( $optstr eq 'searchshows' )) {
		my $JSON = decode_json ${ $http->contentRef };
		_parseItems( $JSON->{data}, $menu );
		_createOffset( $JSON, $passthrough, $menu );
	}elsif( $optstr eq 'categories' )  {
		my $JSON = decode_json ${ $http->contentRef };
		_parseCategories( $JSON->{data}, $menu );
	}elsif ( $optstr eq 'childcategories' ) {
		my $JSON = decode_json ${ $http->contentRef };
		_parseChildCategories( $JSON, $menu );
	}elsif ( $optstr eq 'stationlist' ) {
		my $JSON = decode_json ${ $http->contentRef };
		_parseStationlist( _getDataNode( $JSON->{data}, 'promoted_stations' ),$menu );
		_parseStationlist( _getDataNode( $JSON->{data}, 'local_stations' ),$menu );
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


sub _parseItems {
	my $jsonData = shift;
	my $menu     = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_parseItems");
	my $size = scalar @$jsonData;

	$log->info("Number of items : $size ");

	for my $item (@$jsonData) {

		if ( $item->{type} eq 'playable_item' ) {
			_parsePlayableItem( $item, $menu );
		}elsif ( $item->{type} eq 'container_item' ) {
			_parseContainerItem( $item, $menu );
		}elsif ( $item->{type} eq 'broadcast_summary' ) {
			_parseBroadcastItem( $item, $menu );
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

	$log->info("Number of items : $size ");

	for my $item (@$jsonData) {
		my $image = Plugins::BBCSounds::Utilities::createNetworkLogoUrl($item->{network}->{logo_url});
		push @$menu,
		  {
			name        => $item->{network}->{short_title},
			type        => 'link',
			icon        => $image,
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
	my $item = shift;
	my $menu = shift;
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

	my $iurl = $item->{image_url};
	my $image =Plugins::BBCSounds::PlayManager::createIcon(( _getPidfromImageURL($iurl) ) );

	my $playMenu = [];
	_getPlayableItemMenu($item, $playMenu);

	push @$menu,
	  {
		name => $title,
		type => 'link',
		icon => $image,
		items => $playMenu,
	  };
}


sub _parseBroadcastItem {
	my $item = shift;
	my $menu = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_parseBroadcastItem");

	my $title1 = $item->{titles}->{primary};
	my $title2 = $item->{titles}->{secondary};
	my $title3 = $item->{synopses}->{short};

	my $sttim = str2time( $item->{'start'} );
	my $sttime = strftime( '%H:%M ', localtime($sttim) );

	my $title = $sttime . $title1 . ' - ' . $title2;

	my $iurl = $item->{image_url};
	my $image =Plugins::BBCSounds::PlayManager::createIcon(( _getPidfromImageURL($iurl) ) );

	my $playMenu = [];
	_getPlayableItemMenu($item, $playMenu);

	push @$menu,
	  {
		name => $title,
		type => 'link',
		icon => $image,
		items => $playMenu,
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
	my $podcast = shift;
	my $menu    = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_parseContainerItem");

	my $title = $podcast->{titles}->{primary};
	my $desc  = $podcast->{synopses}->{short};

	my $pid = $podcast->{id};

	my $image =Plugins::BBCSounds::PlayManager::createIcon(_getPidfromImageURL( $podcast->{image_url} ) );

	push @$menu,
	  {
		name        => $title . ' - ' . $desc,
		type        => 'link',
		icon        => $image,
		url         => '',
		passthrough => [
			{
				type    => 'tleo',
				filter  => 'container=' . $pid,
				offset  => 0,
				codeRef => 'getPage'
			}
		],
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
		my $image =Plugins::BBCSounds::PlayManager::createIcon(_getPidfromImageURL( $cat->{image_url} ) );
		push @$menu,
		  {
			name        => $title,
			type        => 'link',
			icon        => $image,
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


sub _getPidfromImageURL {
	my $url = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_getPidfromImageURL");

	main::DEBUGLOG && $log->is_debug && $log->debug("url to create pid : $url");
	my @pid = split /\//x, $url;
	my $pid = pop(@pid);
	$pid = substr $pid, 0, -4;

	main::DEBUGLOG && $log->is_debug && $log->debug("--_getPidfromImageURL - $pid");
	return $pid;
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


sub _parseEditorialTitle {
	my $htmlref = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_parseEditorialTitle");

	my $edJSON = decode_json $$htmlref;
	my $title =
	  $edJSON->{titles}->{primary} . ' - ' . $edJSON->{synopses}->{short};

	main::DEBUGLOG && $log->is_debug && $log->debug("--_parseEditorialTitle - $title");
	return $title;
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

	my $soundsUrl = 'sounds://_' . $id . '_' . $pid . '_' . $timeOffset;

	my $booktype = 'Bookmark';
	my $bookCodeRef = 'createActivity';
	if (_isFavouritedActivity($item->{activities})) {
		$booktype = 'Remove bookmark';
		$bookCodeRef = 'deleteActivity';
	}
	push @$menu,
	  {
		name        => $booktype,
		type        => 'link',
		order 		=> 3,
		url         => '',
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
		my $subCodeRef = 'createActivity';
		if (_isFollowedActivity($item->{container}->{activities})) {
			$subtype = 'Unsubscribe';
			$subCodeRef = 'deleteActivity';
		}
		push @$menu,
		  {
			name        => $subtype,
			type        => 'link',
			order 		=> 4,
			url         => '',
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
			order 		=> 2,
			url         => '',
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
		order 		=> 5,
		url         => '',
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
			order => 6,
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
			name => 'Play' . $playLabel,
			url  => $soundsUrl,
			type => 'audio',
			order => 1,
			passthrough => [ {} ],
			on_select   => 'play',
		  };

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
	main::DEBUGLOG && $log->is_debug && $log->debug("++_isFollowedActivity " . Dumper($activities) );
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
	main::DEBUGLOG && $log->is_debug && $log->debug("++_isFavouritedActivity " . Dumper($activities) );
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

	for my $menuItem (@$menu) {
		my $codeRef = $menuItem->{passthrough}[0]->{'codeRef'};
		if ( defined $codeRef ) {
			if ( $codeRef eq 'getPage' ) {
				$menuItem->{'url'} = \&getPage;
			}elsif ( $codeRef eq 'getSubMenu' ) {
				$menuItem->{'url'} = \&getSubMenu;
			}elsif ( $codeRef eq 'getStationMenu' ) {
				$menuItem->{'url'} = \&getStationMenu;
			}elsif ( $codeRef eq 'handlePlaylist' ) {
				$menuItem->{'url'} =\&Plugins::BBCSounds::PlayManager::handlePlaylist;
			}elsif ( $codeRef eq 'createActivity' ) {
				$menuItem->{'url'} =\&Plugins::BBCSounds::ActivityManagement::createActivity;
			}elsif ( $codeRef eq 'deleteActivity' ) {
				$menuItem->{'url'} =\&Plugins::BBCSounds::ActivityManagement::deleteActivity;
			}elsif ( $codeRef eq 'getPersonalisedPage' ) {
				$menuItem->{'url'} = \&getPersonalisedPage;
			}else {
				$log->error("Unknown Code Reference : $codeRef");
			}
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


sub spottyInfoIntegration {
	my ( $client, $url, $track, $remoteMeta ) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++spottyInfoIntegration");


	my $song = Slim::Player::Source::playingSong($client);
	my $items = [];

	#leave if we are not playing
	return \@$items unless $url && $client && $client->isPlaying;

	#get the meta data
	if ((my $meta = $song->pluginData('meta')) && (Slim::Utils::PluginManager->isEnabled('Plugins::Spotty::Plugin'))) {

		if (!($meta->{spotify} eq '')) {
			$items = [
				{
					name => 'BBC Sounds Now Playing On Spotify',
					type => 'audio',
					url  =>  $meta->{spotify},
					on_select   => 'play'
				}
			];
			main::DEBUGLOG && $log->is_debug && $log->debug("--spottyInfoIntegration");
			return \@$items;
		}
	}else{
		main::INFOLOG && $log->is_info && $log->info("No Meta or spotty available");
		main::DEBUGLOG && $log->is_debug && $log->debug("--spottyInfoIntegration");
		return \@$items;
	}
}

sub recentSearches {
	my ($client, $cb, $params) = @_;

	my $items = [];

	my $i = 0;
	for my $recent ( @{ $prefs->get('sounds_recent_search') || [] } ) {
		unshift @$items, {
			name  => $recent,
			type  => 'link',
			url   => \&getPage,
			itemActions => {
				info => {
					command     => ['sounds', 'recentsearches'],
					fixedParams => { deleteMenu => $i++ },
				},
			},	
			passthrough => [{
				type => 'search',
				query => $recent,
				recent => 1,
				codeRef => 'getPage'
			}],
		};
	}

	unshift @$items, {
		name  => 'New Search',
		type  => 'search',
		url   => \&getPage,
		passthrough => [ { type => 'search' }],
	};

	$cb->({ items => $items });
}


sub tracklistInfoIntegration {
	my ( $client, $url, $track, $remoteMeta ) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++tracklistInfoIntegration");

	my $items = [];

	if (!(Plugins::BBCSounds::ProtocolHandler::isLive(undef,$url))) {
		$items = [
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
			}
		];
	}
	main::DEBUGLOG && $log->is_debug && $log->debug("--tracklistInfoIntegration");
	return \@$items;
}


1;
