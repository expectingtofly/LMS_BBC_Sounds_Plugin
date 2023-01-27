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
use Slim::Utils::DateTime;

use Plugins::BBCSounds::SessionManagement;
use Plugins::BBCSounds::BBCSoundsFeeder;	


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
		$params->{homeMenu} = $prefs->get('homeMenuItems');
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
					my $IDStatus = Plugins::BBCSounds::SessionManagement::getIdentityStatus();
					if ($IDStatus->{sylph}) {
						$params->{sylphExp} = Slim::Utils::DateTime::longDateF($IDStatus->{sylph}) . ' ' . Slim::Utils::DateTime::timeF($IDStatus->{sylph});
					} else {
						$params->{sylphExp} = 'None';
					}
					$params->{sylphExp} = Slim::Utils::DateTime::longDateF($IDStatus->{sylph}) . ' ' . Slim::Utils::DateTime::timeF($IDStatus->{sylph});
					$params->{idExp} = Slim::Utils::DateTime::longDateF($IDStatus->{ID}) . ' ' . Slim::Utils::DateTime::timeF($IDStatus->{ID});

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
		$params->{homeMenu} = $prefs->get('homeMenuItems');
		$log->debug("--handler save sign in");		
		return;
	}

	if ($params->{saveSettings}) {
		if ($params->{clearSearchHistory}) {
			$prefs->set('sounds_recent_search', []);
		}

		Plugins::BBCSounds::BBCSoundsFeeder::setMenuVisibility('unmissibleSounds', $params->{pref_menuitem_unmissibleSounds});
		Plugins::BBCSounds::BBCSoundsFeeder::setMenuVisibility('editorial', $params->{pref_menuitem_editorial});
		Plugins::BBCSounds::BBCSoundsFeeder::setMenuVisibility('recommendations', $params->{pref_menuitem_recommendations});
		Plugins::BBCSounds::BBCSoundsFeeder::setMenuVisibility('localToMe', $params->{pref_menuitem_localToMe});
		Plugins::BBCSounds::BBCSoundsFeeder::setMenuVisibility('continueListening', $params->{pref_menuitem_continueListening});
		Plugins::BBCSounds::BBCSoundsFeeder::setMenuVisibility('SingleItemPromotion', $params->{pref_menuitem_SingleItemPromotion});
		Plugins::BBCSounds::BBCSoundsFeeder::persistHomeMenu();
	}

	my $currentIDStatus = Plugins::BBCSounds::SessionManagement::getIdentityStatus();
	if ($currentIDStatus->{sylph}) {
		$params->{sylphExp} = Slim::Utils::DateTime::longDateF($currentIDStatus->{sylph}) . ' ' . Slim::Utils::DateTime::timeF($currentIDStatus->{sylph});
	} else {
		$params->{sylphExp} = 'None';
	}
	$params->{idExp} = Slim::Utils::DateTime::longDateF($currentIDStatus->{ID}) . ' ' . Slim::Utils::DateTime::timeF($currentIDStatus->{ID});
	
	$params->{homeMenu} = $prefs->get('homeMenuItems');
	$log->debug("--handler");
	return $class->SUPER::handler( $client, $params );
}

sub prefs {
	$log->debug("++prefs");


	$log->debug("--prefs");
	return ($prefs, qw(username password is_radio hideSampleRate displayline1 displayline2 displayline3 displayimage forceHTTP nowPlayingActivityButtons throttleInterval playableAsPlaylist rewoundind ));
}


sub beforeRender {
	my ($class, $paramRef) = @_;
	$log->debug("++beforeRender");

	my $currentIDStatus = Plugins::BBCSounds::SessionManagement::getIdentityStatus();

	$paramRef->{isSignedIn} = 1;
	$paramRef->{isSignedOut} = 0;
	
	if ($currentIDStatus->{sylph}) {
		if ($currentIDStatus->{sylph} < time()) {
			$paramRef->{isSignedIn} = 0;
			$paramRef->{isSignedOut} = 1;
		}
	} else {
		if ($currentIDStatus->{ID}) {
			if ( $currentIDStatus->{ID} < time() ) {
				$paramRef->{isSignedIn} = 0;
				$paramRef->{isSignedOut} = 1;
			}
		} else {
				$paramRef->{isSignedIn} = 0;
				$paramRef->{isSignedOut} = 1;
		}
	}

	$log->debug("--beforeRender");
}

1;
