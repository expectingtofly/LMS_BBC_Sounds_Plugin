package Plugins::BBCSounds::Utilities;

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

use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $log = logger('plugin.bbcsounds');
my $prefs = preferences('plugin.bbcsounds');

use constant MAX_RECENT => 30;

#IMAGE CONSTANTS
use constant IMG_SPEECH => 'plugins/BBCSounds/html/images/Speech_MTL_icon_format_quote.png';
use constant IMG_SUBSCRIBE => 'plugins/BBCSounds/html/images/Subscribe_MTL_icon_rss_feed.png';
use constant IMG_CONTINUE => 'plugins/BBCSounds/html/images/Continue_MTL_icon_subscriptions.png';
use constant IMG_LATEST => 'plugins/BBCSounds/html/images/Latest_MTL_icon_update.png';
use constant IMG_BOOKMARK => 'plugins/BBCSounds/html/images/Bookmark_MTL_icon_add.png';
use constant IMG_MY_SOUNDS => 'plugins/BBCSounds/html/images/MySounds_MTL_icon_recent_actors.png';
use constant IMG_MUSIC => 'plugins/BBCSounds/html/images/Music_MTL_svg_music.png';
use constant IMG_STATIONS => 'plugins/BBCSounds/html/images/Stations_MTL_icon_radio.png';
use constant IMG_BROWSE_CATEGORIES => 'plugins/BBCSounds/html/images/Categories_MTL_icon_library_books.png';
use constant IMG_SEARCH => 'plugins/BBCSounds/html/images/Search_MTL_icon_search.png';
use constant IMG_PLAY => 'plugins/BBCSounds/html/images/Play_MTL_icon_play_arrow.png';
use constant IMG_SYNOPSIS => 'plugins/BBCSounds/html/images/Synopsis_MTL_icon_view_headline.png';
use constant IMG_TRACKS => 'plugins/BBCSounds/html/images/Tracks_MTL_icon_album.png';
use constant IMG_EPISODES => 'plugins/BBCSounds/html/images/Episodes_MTL_icon_dynamic_feed.png';
use constant IMG_RECOMMENDATIONS => 'plugins/BBCSounds/html/images/Personalised_MTL_icon_playlist_add_check.png';
use constant IMG_EDITORIAL => 'plugins/BBCSounds/html/images/Editorial_MTL_icon_star.png';
use constant IMG_FEATURED => 'plugins/BBCSounds/html/images/Featured_MTL_icon_new_releases.png';

use constant IMG_NOWPLAYING_SUBSCRIBE => 'plugins/BBCSounds/html/images/btn_heart_subscribe.gif';
use constant IMG_NOWPLAYING_BOOKMARK => 'plugins/BBCSounds/html/images/btn_thumbsup_bookmark.gif';







sub createNetworkLogoUrl {
	my $logoTemplate = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug("++createNetworkLogoUrl");

	my $logoUrl = $logoTemplate;
	$logoUrl =~ s/{type}/blocks-colour/ig;
	$logoUrl =~ s/{size}/600x600/ig;
	$logoUrl =~ s/{format}/png/ig;

	main::DEBUGLOG && $log->is_debug && $log->debug("--createNetworkLogoUrl");
	return $logoUrl;
}


sub hasRecentSearches {
	return scalar @{ $prefs->get('sounds_recent_search') || [] };
}


sub addRecentSearch {
	my $search = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug("++addRecentSearch");

	my $list = $prefs->get('sounds_recent_search') || [];

	$list = [ grep { $_ ne $search } @$list ];

	push @$list, $search;

	$list = [ @$list[(-1 * MAX_RECENT)..-1] ] if scalar @$list > MAX_RECENT;

	$prefs->set( 'sounds_recent_search', $list );
	main::DEBUGLOG && $log->is_debug && $log->debug("--addRecentSearch");
	return;
}


sub isSoundsURL {
	my $url = shift;

	if ($url =~ /^sounds:\/\//gi) {
		return 1;
	}else{
		return;
	}
}

1;


