package Plugins::BBCSounds::ActivityManagement;

use warnings;
use strict;

use URI::Escape;

use Slim::Utils::Log;
use Slim::Networking::Async::HTTP;
use Plugins::BBCSounds::SessionManagement;
use JSON::XS::VersionOneAndTwo;

my $log = logger('plugin.bbcsounds');

sub createActivity {
    my ( $client, $callback, $args, $passDict ) = @_;
    $log->debug("++createActivity");

    my $urn          = $passDict->{'urn'};
    my $activitytype = $passDict->{'activitytype'};
    my $menu         = [ { name => 'Failed to create ' . $activitytype } ];

    my $body = '{"urn":"' . $urn . '"}';

    Plugins::BBCSounds::SessionManagement::renewSession(
        sub {
            my $session = Slim::Networking::Async::HTTP->new;
            my $request =
              HTTP::Request->new(
                POST => 'https://rms.api.bbc.co.uk/v2/my/activities' );
            $request->header( 'Content-Type' => 'application/json' );
            $request->content($body);

            $session->send_request(
                {
                    request => $request,
                    onBody  => sub {
                        my ( $http, $self ) = @_;
                        my $res = $http->response;
                        $log->debug( 'status - ' . $res->status_line );

                        if (   ( $res->code eq '202' )
                            || ( $res->code eq '200' ) )
                        {
                            $menu =
                              [ { name => "$activitytype succeeded" } ];
                        }
                        $callback->( { items => $menu } );
                    },
                    onError => sub {
                        my ( $http, $self ) = @_;

                        my $res = $http->response;
                        $log->debug( 'Error status - ' . $res->status_line );
                        $callback->( { items => $menu } );
                    }
                }
            );
        },
        sub {
            $callback->( { items => $menu } );
        }
    );
    $log->debug("--createActivity");
    return;
}

sub deleteActivity {
    my ( $client, $callback, $args, $passDict ) = @_;
    $log->debug("++deleteActivity");

    my $urn          = $passDict->{'urn'};
    my $activitytype = $passDict->{'activitytype'};
    my $menu         = [ { name => 'Failed to remove ' . $activitytype } ];

    my $body = '{"urn":"' . $urn . '"}';

    Plugins::BBCSounds::SessionManagement::renewSession(
        sub {
            my $session = Slim::Networking::Async::HTTP->new;
            my $request =
              HTTP::Request->new(
                DELETE => 'https://rms.api.bbc.co.uk/v2/my/activities' );
            $request->header( 'Content-Type' => 'application/json' );
            $request->content($body);

            $session->send_request(
                {
                    request => $request,
                    onBody  => sub {
                        my ( $http, $self ) = @_;
                        my $res = $http->response;
                        $log->debug( 'status - ' . $res->status_line );

                        if (   ( $res->code eq '202' )
                            || ( $res->code eq '200' ) )
                        {
                            $menu = [
                                {
                                        name => 'removal of '
                                      . $activitytype
                                      . ' succeeded'
                                }
                            ];
                        }
                        $callback->( { items => $menu } );
                    },
                    onError => sub {
                        my ( $http, $self ) = @_;

                        my $res = $http->response;
                        $log->debug( 'Error status - ' . $res->status_line );
                        $callback->( { items => $menu } );
                    }
                }
            );
        },
        sub {
            $callback->( { items => $menu } );
        }
    );
    $log->debug("--deleteActivity");
    return;
}

1;
