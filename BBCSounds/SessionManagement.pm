package Plugins::BBCSounds::SessionManagement;


#  stu@expectingtofly.co.uk
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


use warnings;
use strict;

use Slim::Networking::Async::HTTP;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use HTTP::Request::Common;
use HTML::Entities;
use HTTP::Cookies;
use JSON::XS::VersionOneAndTwo;

use Data::Dumper;

use constant TOKEN_RENEW    => 62370000; # 3 weeks less than 2 years

my $log   = logger('plugin.bbcsounds');
my $prefs = preferences('plugin.bbcsounds');


sub signIn {
	my $username = shift;
	my $password = shift;
	my $cbYes = shift;
	my $cbNo  = shift;

	main::DEBUGLOG && $log->is_debug && $log->debug("++signIn");

	my $fSignIn = sub {
		
		my %body1 = (
			username  => $username,
		);
		
		my %body2 = (			
			username  => $username,
			password  => $password,
		);

		#get the session this gives us access to the cookies
		my $session = Slim::Networking::Async::HTTP->new;

		my $initrequest = HTTP::Request->new( GET => 'https://account.bbc.com' );
		$initrequest->header( 'Accept-Language' => 'en-GB,en;q=0.9' );
		$session->send_request(
			{
				request => $initrequest,
				onBody  => sub {
					my ( $http, $self ) = @_;
					my $res = $http->response;
					my $req = $http->request;
					my ($signinurl) =$res->content =~ /<form\s+(?:[^>]*?\s+)?action="([^"]*)"/;

					main::DEBUGLOG && $log->is_debug && $log->debug("url $signinurl");
					$signinurl = HTML::Entities::decode_entities($signinurl);
					my $referUrl = $req->uri;
					$signinurl = 'https://account.bbc.com' . $signinurl;

					my $requestUserName =HTTP::Request::Common::POST( $signinurl, [%body1] );
					$requestUserName->header( 'Referer' => $referUrl );
					$requestUserName->header( 'Origin'  => 'https://account.bbc.com' );
					$requestUserName->header( 'Accept-Language' => 'en-GB,en;q=0.9' );
					$requestUserName->header( 'Accept' =>'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.9');
					$requestUserName->header( 'Cache-Control' => 'max-age=0' );

					$session->send_request(
						{
							request => $requestUserName,
							onBody  => sub {
								my ( $http, $self ) = @_;
								my $res = $http->response;

								main::DEBUGLOG && $log->is_debug && $log->debug('Initial UserName Request Succeed ');
								my ($newSigninurl) =$res->content =~ /<form\s+(?:[^>]*?\s+)?action="([^"]*)"/;

								main::DEBUGLOG && $log->is_debug && $log->debug("New url $newSigninurl");
								$newSigninurl = HTML::Entities::decode_entities($newSigninurl);
								my $referUrl = $req->uri;
								$newSigninurl = 'https://account.bbc.com' . $newSigninurl;

								my $requestFull = HTTP::Request::Common::POST( $newSigninurl, [%body2] );
								$requestFull->header( 'Referer' => $referUrl );
								$requestFull->header( 'Origin'  => 'https://account.bbc.com' );
								$requestFull->header( 'Accept-Language' => 'en-GB,en;q=0.9' );
								$requestFull->header( 'Accept' =>'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.9');
								$requestFull->header( 'Cache-Control' => 'max-age=0' );
												
								$session->send_request(
									{
										request => $requestFull,
										onBody  => sub {
											my ( $http, $self ) = @_;
											my $res = $http->response;

											main::DEBUGLOG && $log->is_debug && $log->debug('Cookies on final body : ' . Dumper($session->cookie_jar));

											#makes sure the cookies are persisted
											$session->cookie_jar->save();

											$cbYes->();
										},
										onRedirect => sub {
											my ( $req, $self ) = @_;

											#try and change the method to get, as it automatically keeps it as post
											if ( $req->method eq 'POST' ) {
												$req->method('GET');
											}

											main::DEBUGLOG && $log->is_debug && $log->debug('Cookies on Redirect : ' . Dumper($session->cookie_jar));


										},
										onError => sub {
											my ( $http, $self ) = @_;
											my $res = $http->response;
											$log->warn('Error status - ' . $res->status_line );
											$cbNo->();
										}
									}
								);
								
							},
							onError =>
				  			# Called when no response was received or an error occurred.
				  			sub {
								$log->warn("error: $_[1]");
								$cbNo->();
							}
						}
					);
				},
				onError =>

				  # Called when no response was received or an error occurred.
				  sub {
					$log->warn("error: $_[1]");
					$cbNo->();
				}
			}
		);
	};

	ensureCookiesAreCleared();
	$fSignIn->();

	main::DEBUGLOG && $log->is_debug && $log->debug("--signIn");
	return;
}


sub ensureCookiesAreCleared {
	main::DEBUGLOG && $log->is_debug && $log->debug("++ensureCookiesAreCleared");
	my $session   = Slim::Networking::Async::HTTP->new;
	my $cookiejar = $session->cookie_jar;

	main::DEBUGLOG && $log->is_debug && $log->debug('Before Clear cookies : ' . Dumper($cookiejar));

	$cookiejar->clear('.bbc.co.uk');
	$cookiejar->clear('account.bbc.com');
	$cookiejar->clear('session.bbc.co.uk');
	$session->cookie_jar->save();
	main::DEBUGLOG && $log->is_debug && $log->debug('After Clear cookies : ' . Dumper($cookiejar));

	main::DEBUGLOG && $log->is_debug && $log->debug("--ensureCookiesAreCleared");
	return;
}


sub isSignedIn {
	main::DEBUGLOG && $log->is_debug && $log->debug("++isSignedIn");
	my $session   = Slim::Networking::Async::HTTP->new;
	my $cookiejar = $session->cookie_jar;
	my $key       = $cookiejar->{COOKIES}->{'.bbc.co.uk'}->{'/'}->{'ckns_id'};
	if ( defined $key ) {
		my $cookieepoch = @{$key}[5];
		if (defined $cookieepoch) {
			my $epoch       = time();
			if ( $epoch < $cookieepoch ) {
				main::DEBUGLOG && $log->is_debug && $log->debug("--isSignedIn - true $epoch - $cookieepoch");
				return 1;
			}else{
				main::DEBUGLOG && $log->is_debug && $log->debug("--isSignedIn - false");
				return;
			}
		}else{
			main::DEBUGLOG && $log->is_debug && $log->debug("--isSignedIn - false");
			return;
		}
	}else {
		main::DEBUGLOG && $log->is_debug && $log->debug("--_isSignedIn - false");
		return;
	}
}


sub signOut {
	my $cbYes = shift;
	my $cbNo  = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug("++signOut");
	my $session = Slim::Networking::Async::HTTP->new;
	my $sessionrequest =HTTP::Request->new( GET => 'https://session.bbc.com/session/signout?ptrt=https%3A%2F%2Faccount.bbc.com%2Fsignout&switchTld=1' );

	$session->send_request(
		{
			request => $sessionrequest,
			onBody  => sub {
				my ( $http, $self ) = @_;
				$session->cookie_jar->save();
				$cbYes->();
				main::DEBUGLOG && $log->is_debug && $log->debug("--signOut");
				return;
			},
			onError => sub {
				my ( $http, $self ) = @_;
				my $res = $http->response;
				main::DEBUGLOG && $log->is_debug && $log->debug( 'Error status - ' . $res->status_line );
				$cbNo->();
				main::DEBUGLOG && $log->is_debug && $log->debug("--signOut");
				return;
			}
		}
	);
}


sub renewSession {
	main::DEBUGLOG && $log->is_debug && $log->debug("++renewSession");
	my $cbYes = shift;
	my $cbNo  = shift;

	if ( isSignedIn() ) {
		if ( _hasSession() ) {
			$cbYes->();
			main::DEBUGLOG && $log->is_debug && $log->debug("--renewSession already");
			return;
		}else {

			my $session = Slim::Networking::Async::HTTP->new;

			my $sessionrequest =HTTP::Request->new( GET =>'https://session.bbc.co.uk/session?context=iplayerradio&userOrigin=sounds');
			$session->send_request(
				{
					request => $sessionrequest,
					onBody  => sub {
						my ( $http, $self ) = @_;
						$session->cookie_jar->save();
						if ( _hasSession() ) {
							$cbYes->();
							main::DEBUGLOG && $log->is_debug && $log->debug("--renewSession");
							return;
						}else {
							$log->warn("Failed to get session cookie");
							$cbNo->();
							main::DEBUGLOG && $log->is_debug && $log->debug("--renewSession failed to get cookie");
							return;
						}
					},
					onError => sub {
						my ( $http, $self ) = @_;
						my $res = $http->response;
						$log->warn("Could not renew session error : " . $res->status_line);
						main::DEBUGLOG && $log->is_debug && $log->debug( 'Error status - ' . $res->status_line );
						$cbNo->();
						main::DEBUGLOG && $log->is_debug && $log->debug("--renewSession renew session failed");
						return;
					}
				}
			);
		}
	}else {
		$cbNo->();
		main::DEBUGLOG && $log->is_debug && $log->debug("--renewSession not signed in");
		return;
	}
}


sub getIdentityStatus {
	main::DEBUGLOG && $log->is_debug && $log->debug("++getIdentityStatus");
	my $session   = Slim::Networking::Async::HTTP->new;
	my $cookiejar = $session->cookie_jar;

	my $keyId     = $cookiejar->{COOKIES}->{'.bbc.co.uk'}->{'/'}->{'ckns_id'};
	my $keySylph  = $cookiejar->{COOKIES}->{'.bbc.co.uk'}->{'/'}->{'ckns_sylphid'};

	my $resp = { sylph => 0, ID => 0 };

	$resp->{sylph} = @{$keySylph}[5] if (defined $keySylph);
	$resp->{ID} = @{$keyId}[5] if (defined $keyId);

	main::DEBUGLOG && $log->is_debug && $log->debug("--getIdentityStatus");
	return $resp;
}


sub _hasSession {
	main::DEBUGLOG && $log->is_debug && $log->debug("++_hasSession");
	my $session   = Slim::Networking::Async::HTTP->new;
	my $cookiejar = $session->cookie_jar;
	my $key       = $cookiejar->{COOKIES}->{'.bbc.co.uk'}->{'/'}->{'ckns_atkn'};
	if ( defined $key ) {
		my $cookieepoch = @{$key}[5];
		my $epoch       = time();

		if ( $epoch < $cookieepoch ) {
			main::DEBUGLOG && $log->is_debug && $log->debug("--_hasSession - true");
			return 1;
		}else {
			main::DEBUGLOG && $log->is_debug && $log->debug("--_hasSession - false");
			return;
		}

	}else {
		main::DEBUGLOG && $log->is_debug && $log->debug("--_hasSession - false");
		return;
	}
}


sub getLiveStreamJwt {
	my $id = shift;
	my $cbY = shift;
	my $cbN = shift;

	main::DEBUGLOG && $log->is_debug && $log->debug("++getLiveStreamJwt");

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;
			main::DEBUGLOG && $log->is_debug && $log->debug('Have JWT');
			my $JSON = decode_json ${ $http->contentRef };

			if (my $jwt = $JSON->{token}) {

				main::DEBUGLOG && $log->is_debug && $log->debug('JWT obtained ' . $jwt);

				$cbY->($jwt);
			} else {
				$log->warn('JWT Not Found');
				$cbN->();
			}
		},

		# Called when no response was received or an error occurred.
		sub {
			$log->warn("error: $_[1]");
			$log->warn("Could not get JWT token");
			$cbN->();
		}
	)->get('https://rms.api.bbc.co.uk/v2/sign/token/' . $id);
	
	main::DEBUGLOG && $log->is_debug && $log->debug("--getLiveStreamJwt");
	return;
}
1;

