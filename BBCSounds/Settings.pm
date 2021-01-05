package Plugins::BBCSounds::Settings;

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

	if ($params->{signout}) {
		Plugins::BBCSounds::SessionManagement::signOut(
			sub {
				$log->info("Sign out successful");

				my $msg ='<strong>There was a problem with sign out, please try again</strong>';
				my $isValid = 0;
				if ( !(Plugins::BBCSounds::SessionManagement::isSignedIn())){
					$isValid = 0;
					$msg ='<strong>Successfully signed out</strong>';
				}

				$params->{warning} .= $msg . '<br/>';
				my $body = $class->SUPER::handler( $client, $params );

				if ( $params->{AJAX} ) {
					$params->{warning} = $msg;
					$params->{validated}->{valid} = $isValid;
				}else {
					$params->{warning} .= $msg . '<br/>';
				}

				$callback->( $client, $params, $body, @args );
			},
			sub {
				$log->error("Sign out failed");

				my $msg = '<strong>There was a problem with sign in, please try again</strong>';
				$params->{warning} .= $msg . '<br/>';
				if ( $params->{AJAX} ) {
					$params->{warning} = $msg;
					$params->{validated}->{valid} = 0;
				}else {
					$params->{warning} .= $msg . '<br/>';
				}
				my $body = $class->SUPER::handler( $client, $params );
				$callback->( $client, $params, $body, @args );

			}
		);
		$log->debug("--handler save sign out");
		return;
	}

	if ( $params->{signin} ) {

		Plugins::BBCSounds::SessionManagement::signIn(
			$params->{pref_username},
			$params->{pref_password},
			sub {
				my $msg ='<strong>There was a problem with sign in, please try again</strong>';
				my $isValid = 0;
				if ( Plugins::BBCSounds::SessionManagement::isSignedIn()){
					$isValid = 0;
					$msg ='<strong>Successfully signed in</strong>';
				}
				$params->{warning} .= $msg . '<br/>';
				my $body = $class->SUPER::handler( $client, $params );

				if ( $params->{AJAX} ) {
					$params->{warning} = $msg;
					$params->{validated}->{valid} = $isValid;
				}else {
					$params->{warning} .= $msg . '<br/>';
				}
				$params->{pref_username} = '';
				$params->{pref_password} = '';

				$callback->( $client, $params, $body, @args );
			},
			sub {
				my $msg ='<strong>There was a problem with sign in, please try again</strong>';
				$params->{warning} .= $msg . '<br/>';
				if ( $params->{AJAX} ) {
					$params->{warning} = $msg;
					$params->{validated}->{valid} = 0;
				}else {
					$params->{warning} .= $msg . '<br/>';
				}

				delete $params->{pref_username};
				delete $params->{pref_password};
				my $body = $class->SUPER::handler( $client, $params );
				$callback->( $client, $params, $body, @args );
			}
		);
		$log->debug("--handler save sign in");
		return;
	}

	if ($params->{saveSettings}) {
		if ($params->{clearSearchHistory}) {
			$prefs->set('sounds_recent_search', []);
		}
	}

	$log->debug("--handler");
	return $class->SUPER::handler( $client, $params );
}


sub prefs {
	$log->debug("++prefs");


	$log->debug("--prefs");
	return ( $prefs, qw(username password is_radio hideSampleRate alternate_track alternate_track_image fix_track track_line_three) );
}


sub beforeRender {
	my ($class, $paramRef) = @_;
	$log->debug("++beforeRender");

	my $isSignedIn = Plugins::BBCSounds::SessionManagement::isSignedIn();

	$paramRef->{isSignedIn} = $isSignedIn;

	$paramRef->{isSignedOut} =  !($isSignedIn);

	$log->debug("--beforeRender");
}

1;
