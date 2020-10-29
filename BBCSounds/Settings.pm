package Plugins::BBCSounds::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;
use Slim::Utils::Log;

use Plugins::BBCSounds::SessionManagement;

use Data::Dumper;

my $prefs = preferences('plugin.bbcsounds');

my $log = logger('plugin.bbcsounds');

sub name {
    return 'PLUGIN_BBCSOUNDS';
}

sub page {
    return 'plugins/BBCSounds/settings/basic.html';
}

sub handler {
    my ( $class, $client, $params, $callback, @args ) = @_;
    $log->debug("++handler");

    if ( $params->{saveSettings} ) {
        Plugins::BBCSounds::SessionManagement::signOut(
            sub {
                Plugins::BBCSounds::SessionManagement::signIn(
                    $params->{pref_username},
                    $params->{pref_password},
                    sub {
                        my $msg =
                          '<strong>There was a problem with sign in, please try again</strong>';
                        my $isValid = 0;
                        if ( Plugins::BBCSounds::SessionManagement::isSignedIn()
                          )
                        {
                            $isValid = 0;
                            $msg =
                              '<strong>Successfully signed in</strong>';
                        }
                        $params->{warning} .= $msg . '<br/>';
                        my $body = $class->SUPER::handler( $client, $params );

                        if ( $params->{AJAX} ) {
                            $params->{warning} = $msg;
                            $params->{validated}->{valid} = $isValid;
                        }
                        else {
                            $params->{warning} .= $msg . '<br/>';
                        }
                        $params->{pref_username} = '';
                        $params->{pref_password} = '';

                        $callback->( $client, $params, $body, @args );
                    },
                    sub {
                        my $msg =
                          '<strong>There was a problem with sign in, please try again</strong>';
                        $params->{warning} .= $msg . '<br/>';
                        if ( $params->{AJAX} ) {
                            $params->{warning} = $msg;
                            $params->{validated}->{valid} = 0;
                        }
                        else {
                            $params->{warning} .= $msg . '<br/>';
                        }

                        delete $params->{pref_username};
                        delete $params->{pref_password};
                        my $body = $class->SUPER::handler( $client, $params );
                        $callback->( $client, $params, $body, @args );
                    }
                );
            },
            sub {
                my $msg = '<strong>There was a problem with sign in, please try again</strong>';
                $params->{warning} .= $msg . '<br/>';
                if ( $params->{AJAX} ) {
                    $params->{warning} = $msg;
                    $params->{validated}->{valid} = 0;
                }
                else {
                    $params->{warning} .= $msg . '<br/>';
                }

                delete $params->{pref_username};
                delete $params->{pref_password};
                my $body = $class->SUPER::handler( $client, $params );
                $callback->( $client, $params, $body, @args );
            }
        );
        $log->debug("--handler save");
        return;
    }
    $log->debug("--handler");
    return $class->SUPER::handler( $client, $params );
}

sub prefs {
    $log->debug("++prefs");


    $log->debug("--prefs");
    return ( $prefs, qw(username password) );
}

sub beforeRender {
	my ($class, $paramRef) = @_;
	$log->debug("++beforeRender");
	
	$paramRef->{isSignedIn} = Plugins::BBCSounds::SessionManagement::isSignedIn();
	
	$log->debug("--beforeRender");
}

1;
