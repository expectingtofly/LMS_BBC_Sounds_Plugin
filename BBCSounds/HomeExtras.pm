package Plugins::BBCSounds::HomeExtras;

use strict;

use Plugins::BBCSounds::BBCSoundsFeeder;
use Plugins::BBCSounds::SessionManagement;
use Plugins::BBCSounds::Utilities;
use Slim::Utils::Log;

my $log   = logger('plugin.bbcsounds');


Plugins::BBCSounds::HomeExtraBBCSounds->initPlugin();
Plugins::BBCSounds::HomeExtraSubscriptions->initPlugin();
Plugins::BBCSounds::HomeExtraLatest->initPlugin();
Plugins::BBCSounds::HomeExtraTopContinueListening->initPlugin();
Plugins::BBCSounds::HomeExtraBookmarks->initPlugin();
Plugins::BBCSounds::HomeExtraNewsPlaylist->initPlugin();
Plugins::BBCSounds::HomeExtraRecommendations->initPlugin();

1;

package Plugins::BBCSounds::HomeExtraBase;

use base qw(Plugins::MaterialSkin::HomeExtraBase);

sub initPlugin {
	my ($class, %args) = @_;

	my $tag = $args{tag};
	my $source = $args{source};
	my $urn = $args{urn} || undef;

	$class->SUPER::initPlugin(
		feed => sub { handleFeed($tag, $source, $urn, @_) },
		tag  => "BBCSoundsExtras${tag}",
		extra => {
			title => $args{title},
            subtitle => $args{subtitle} || '',
			icon  => $args{icon} || Plugins::BBCSounds::Utilities::IMG_BBCSOUNDS,
			needsPlayer => 1,
		}
	);
}

sub handleFeed {
	my ($tag, $source, $urn, $client, $cb, $args) = @_;
    
    if ($source eq 'home' ) {
        Plugins::BBCSounds::BBCSoundsFeeder::toplevel($client, $cb, undef);
    } elsif ($source eq 'personalised' ) {
        Plugins::BBCSounds::BBCSoundsFeeder::getPersonalisedPage($client, $cb, {quantity => 0}, {type => $tag, isForHomeExtras => 1} );        
    } else {
		Plugins::BBCSounds::SessionManagement::renewSession(
			sub {
				my $actualTag = $urn ? 'inlineURN' : $tag;
				Plugins::BBCSounds::BBCSoundsFeeder::getPage($client, $cb, undef, {type => $actualTag, urn => $urn, offset  => 0 } );
			},
			#could not get a session
			sub {
				my $menu = [ { name => 'Failed to get menu - Could not get session' } ];
				$cb->( { items => $menu } );
			}
		);
	}
}

1;

package Plugins::BBCSounds::HomeExtraBBCSounds;

use base qw(Plugins::BBCSounds::HomeExtraBase);

sub initPlugin {
	my ($class, %args) = @_;

	$class->SUPER::initPlugin(
		title => 'BBC Sounds',
        subtitle => 'Home menu',
		tag => 'home',
		source => 'home'
	);
}

1;


package Plugins::BBCSounds::HomeExtraSubscriptions;

use base qw(Plugins::BBCSounds::HomeExtraBase);

sub initPlugin {
	my ($class, %args) = @_;

	$class->SUPER::initPlugin(
		title => 'BBC Sounds Subscriptions',
        subtitle => 'My Sounds subscriptions',
		tag => 'subscribed',
		source => 'personalised'
	);
}

1;


package Plugins::BBCSounds::HomeExtraLatest;

use base qw(Plugins::BBCSounds::HomeExtraBase);

sub initPlugin {
	my ($class, %args) = @_;

	$class->SUPER::initPlugin(
		title => 'BBC Sounds Latest',
        subtitle => 'Latest episododes from your subscriptions',
		tag => 'latest',
		source => 'personalised'
	);
}

1;


package Plugins::BBCSounds::HomeExtraTopContinueListening;

use base qw(Plugins::BBCSounds::HomeExtraBase);

sub initPlugin {
	my ($class, %args) = @_;

	$class->SUPER::initPlugin(
		title => 'BBC Sounds Continue Listening',
		subtitle => 'Continue listening to your recently played episodes and series',
		tag => 'continue',
		source => 'personalised'
	);
}

1;


package Plugins::BBCSounds::HomeExtraBookmarks;

use base qw(Plugins::BBCSounds::HomeExtraBase);

sub initPlugin {
	my ($class, %args) = @_;

	$class->SUPER::initPlugin(
		title => 'BBC Sounds Bookmarks',
        subtitle => 'My Sounds bookmarked episodes',
		tag => 'bookmarks',
		source => 'personalised'
	);
}

1;

package Plugins::BBCSounds::HomeExtraNewsPlaylist;

use base qw(Plugins::BBCSounds::HomeExtraBase);

sub initPlugin {
	my ($class, %args) = @_;

	$class->SUPER::initPlugin(
		title => 'BBC Sounds Latest News',
        subtitle => 'Latest news from the BBC',
		tag => 'news',
		source => 'standard',
		urn => 'urn:bbc:radio:curation:m001bm45'
	);
}

1;

package Plugins::BBCSounds::HomeExtraRecommendations;

use base qw(Plugins::BBCSounds::HomeExtraBase);

sub initPlugin {
	my ($class, %args) = @_;

	$class->SUPER::initPlugin(
		title => 'BBC Sounds Recommendations For You',
        subtitle => 'Personal recommendations from BBC Sounds',
		tag => 'recommendations',
		source => 'standard'
	);
}

1;

