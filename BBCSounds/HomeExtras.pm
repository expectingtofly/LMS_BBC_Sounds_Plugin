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

1;

package Plugins::BBCSounds::HomeExtraBase;

use base qw(Plugins::MaterialSkin::HomeExtraBase);

sub initPlugin {
	my ($class, %args) = @_;

	my $tag = $args{tag};

	$class->SUPER::initPlugin(
		feed => sub { handleFeed($tag, @_) },
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
	my ($tag, $client, $cb, $args) = @_;
    
    if ($tag eq 'home' ) {
        Plugins::BBCSounds::BBCSoundsFeeder::toplevel($client, $cb, undef);
    } else {            
        Plugins::BBCSounds::BBCSoundsFeeder::getPersonalisedPage($client, $cb, {quantity => 0}, {type => $tag, isForHomeExtras => 1} );        
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
		tag => 'home'
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
		tag => 'subscribed'
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
		tag => 'latest'
	);
}

1;


package Plugins::BBCSounds::HomeExtraTopContinueListening;

use base qw(Plugins::BBCSounds::HomeExtraBase);

sub initPlugin {
	my ($class, %args) = @_;

	$class->SUPER::initPlugin(
		title => 'BBC Sounds Continue Listening',
		tag => 'continue'
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
		tag => 'bookmarks'
	);
}

1;