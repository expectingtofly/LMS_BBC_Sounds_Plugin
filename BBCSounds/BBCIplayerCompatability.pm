package Plugins::BBCSounds::BBCIplayerCompatability;

use warnings;
use strict;

use URI::Escape;
use JSON::XS::VersionOneAndTwo;

use Slim::Utils::Log;

my $log = logger('plugin.bbcsounds');

sub createIplayerParser {
    my $pid   = shift;
    my $icon  = shift;
    my $title = shift;
    my $desc  = shift;

    $log->debug("++createIplayerParser");

    my $dashmediaSelector =
"http://open.live.bbc.co.uk/mediaselector/6/redir/version/2.0/mediaset/audio-syndication-dash/proto/http/vpid/$pid";
    my $hlsmediaselector =
"http://open.live.bbc.co.uk/mediaselector/6/redir/version/2.0/$pid/mediaset/audio-syndication/proto/http";

    my $iplayerParser =
        'Plugins::BBCiPlayer::PlaylistParser?' . 'dash='
      . $dashmediaSelector . '&hls='
      . $hlsmediaselector
      . '&icon='
      . $icon
      . '&title='
      . URI::Escape::uri_escape_utf8($title)
      . '&desc='
      . URI::Escape::uri_escape_utf8($desc);

    $log->debug("--createIplayerParser");
    return $iplayerParser;
}

sub createIplayerIcon {
    my $pid = shift;
    $log->debug("++createIplayerIcon");

    my $iplayerIcon = "http://ichef.bbci.co.uk/images/ic/320x320/$pid.jpg";

    $log->debug("--createIplayerIcon - $iplayerIcon");
    return $iplayerIcon;
}

sub createIplayerPlaylist {
    my $pid = shift;
    $log->debug("++createIplayerPlaylist");

    my $playlist_url = "http://www.bbc.co.uk/programmes/$pid/playlist.json";

    $log->debug("--createIplayerPlaylist - $playlist_url");
    return $playlist_url;
}

sub handlePlaylist {
    my ( $client, $callback, $args, $passDict ) = @_;
    $log->debug("++handlePlaylist");

    my $gpid = $passDict->{'pid'};
    my $url  = createIplayerPlaylist($gpid);

    my $menu = [];
    my $fetch;

    $fetch = sub {

        $log->debug("fetching: $url");
        Slim::Networking::SimpleAsyncHTTP->new(
            sub {
                my $http = shift;
                parsePlaylist( $http->contentRef, $menu, $gpid );
                $callback->(
                    { items => $menu, cachetime => 0, replaceparent => 1 } );
            },

            # Called when no response was received or an error occurred.
            sub {
                $log->warn("error: $_[1]");
                $callback->( [ { name => $_[1], type => 'text' } ] );
            },
        )->get($url);
    };

    $fetch->();
    $log->debug("--handlePlaylist");
    return;
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

    my $dashmediaSelector =
"http://open.live.bbc.co.uk/mediaselector/6/redir/version/2.0/mediaset/audio-syndication-dash/proto/http/vpid/$pid";
    my $hlsmediaselector =
"http://open.live.bbc.co.uk/mediaselector/6/redir/version/2.0/$pid/mediaset/audio-syndication/proto/http";
    my $title = $playlistJSON->{defaultAvailableVersion}->{smpConfig}->{title};
    my $desc = $playlistJSON->{defaultAvailableVersion}->{smpConfig}->{summary};
    my $icon = createIplayerIcon(
        _getPidfromImageURL(
            $playlistJSON->{defaultAvailableVersion}->{smpConfig}
              ->{holdingImageURL}
        )
    );

    my $stream =
        'iplayer://aod?' . 'dash='
      . URI::Escape::uri_escape_utf8($dashmediaSelector) . '&hls='
      . URI::Escape::uri_escape_utf8($hlsmediaselector)
      . '&icon='
      . URI::Escape::uri_escape_utf8($icon)
      . '&title='
      . URI::Escape::uri_escape_utf8($title)
      . '&desc='
      . URI::Escape::uri_escape_utf8($desc);

    $log->info("aod stream $stream");
    
    $stream =  'sounds://' . $pid;
    
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

