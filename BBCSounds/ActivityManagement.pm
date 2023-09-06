package Plugins::BBCSounds::ActivityManagement;

#  (c) stu@expectingtofly.co.uk  2020
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

use URI::Escape;

use Slim::Utils::Log;
use Slim::Networking::Async::HTTP;
use Plugins::BBCSounds::SessionManagement;
use JSON::XS::VersionOneAndTwo;

my $log = logger('plugin.bbcsounds');


sub createActivity {
	my ( $callback,  $passDict ) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++createActivity");

	my $urn          = $passDict->{'urn'};
	my $activitytype = $passDict->{'activitytype'};
	my $result =  'Failed to create ' . $activitytype;

	my $body = '{"urn":"' . $urn . '"}';

	Plugins::BBCSounds::SessionManagement::renewSession(
		sub {
			my $session = Slim::Networking::Async::HTTP->new;
			my $request =HTTP::Request->new(POST => 'https://rms.api.bbc.co.uk/v2/my/activities' );
			$request->header( 'Content-Type' => 'application/json' );
			$request->content($body);

			$session->send_request(
				{
					request => $request,
					onBody  => sub {
						my ( $http, $self ) = @_;
						my $res = $http->response;
						main::DEBUGLOG && $log->is_debug && $log->debug( 'status - ' . $res->status_line );
						my $result = '';
						if (   ( $res->code eq '202' )
							|| ( $res->code eq '200' ) ){
							$result =  ucfirst($activitytype) . ' succeeded';
						}
						$callback->( $result );
					},
					onError => sub {
						my ( $http, $self ) = @_;

						my $res = $http->response;
						main::DEBUGLOG && $log->is_debug && $log->debug( 'Error status - ' . $res->status_line );
						$callback->( $result );
					}
				}
			);
		},
		sub {
			$callback->( $result);
		}
	);
	main::DEBUGLOG && $log->is_debug && $log->debug("--createActivity");
	return;
}


sub heartBeat {
	my $vpid = shift;
	my $pid  = shift;
	my $type = shift;
	my $time = shift;

	my $body ='{"resource_type":"episode","pid":"'. $pid. '","version_pid":"'. $vpid. '","elapsed_time":'. $time. ',"action":"'. $type . '"}';

	main::INFOLOG && $log->is_info && $log->info( 'heartbeat  - ' . $body );

	Plugins::BBCSounds::SessionManagement::renewSession(
		sub {
			my $session = Slim::Networking::Async::HTTP->new;
			my $request =HTTP::Request->new(POST => 'https://rms.api.bbc.co.uk/v2/my/programmes/plays' );
			$request->header( 'Content-Type' => 'application/json' );
			$request->content($body);

			$session->send_request(
				{
					request => $request,
					onBody  => sub {
						my ( $http, $self ) = @_;
						my $res = $http->response;
						main::DEBUGLOG && $log->is_debug && $log->debug('heartbeat status - ' . $res->status_line );
					},
					onError => sub {
						my ( $http, $self ) = @_;

						my $res = $http->response;
						$log->error('Heartbeat Error status - ' . $res->status_line );
					}
				}
			);
		},
		sub {
			$log->error('heartbeat failed');
		}
	);

}


sub deleteActivity {
	my ( $callback, $passDict ) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++deleteActivity");

	my $urn          = $passDict->{'urn'};
	my $activitytype = $passDict->{'activitytype'};
	my $result = 'Failed to remove ' . $activitytype;


	Plugins::BBCSounds::SessionManagement::renewSession(
		sub {
			my $session = Slim::Networking::Async::HTTP->new;
			my $request =HTTP::Request->new(DELETE => 'https://rms.api.bbc.co.uk/v2/my/activities/' . $urn );

			$session->send_request(
				{
					request => $request,
					onBody  => sub {
						my ( $http, $self ) = @_;
						my $res = $http->response;
						main::DEBUGLOG && $log->is_debug && $log->debug( 'status - ' . $res->status_line );

						if (   ( $res->code eq '202' )
							|| ( $res->code eq '200' ) ) {
							$result = 'Removal of '. $activitytype. ' succeeded';
						}
						$callback->( $result );
					},
					onError => sub {
						my ( $http, $self ) = @_;

						my $res = $http->response;
						$log->error( 'Error status - ' . $res->status_line );
						$callback->( $result );
					}
				}
			);
		},
		sub {
			$callback->( $result );
		}
	);
	main::DEBUGLOG && $log->is_debug && $log->debug("--deleteActivity");
	return;
}

1;
