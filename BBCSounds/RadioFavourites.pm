package Plugins::BBCSounds::RadioFavourites;

# Copyright (C) 2021 Stuart McLean stu@expectingtofly.co.uk

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

use Slim::Utils::Log;
use JSON::XS::VersionOneAndTwo;
use HTTP::Date;
use Data::Dumper;

my $log = logger('plugin.bbcsounds');
use constant RF_STATIONIMAGE => "https://sounds.files.bbci.co.uk/2.3.0/networks/{station}/colour_default.svg";


sub getStationSchedule {
	my ( $stationUrl, $stationKey, $stationName, $scheduleDate, $cbSuccess, $cbError) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++getStationSchedule");


	Plugins::BBCSounds::SessionManagement::renewSession(
		sub {
			my $callurl = 'https://rms.api.bbc.co.uk/v2/experience/inline/schedules/'. $stationKey . '/'. $scheduleDate;
			main::DEBUGLOG && $log->is_debug && $log->debug("fetching: $callurl");

			Slim::Networking::SimpleAsyncHTTP->new(
				sub {
					my $http = shift;

					my $JSON = decode_json ${ $http->contentRef };
					my $datanode = Plugins::BBCSounds::BBCSoundsFeeder::_getDataNode( $JSON->{data}, 'schedule_items' );

					my $out = [];

					for my $item (@$datanode) {
						my $image = Plugins::BBCSounds::PlayManager::createIcon($item->{image_url});
						push @$out,
						  {
							start => $item->{start},
							end => $item->{end},
							title1 => $item->{titles}->{primary},
							title2 => $item->{titles}->{secondary},
							image => $image,
						  };
					}

					$cbSuccess->($out);

				},

				# Called when no response was received or an error occurred.
				sub {
					$log->warn("error: $_[1]");
					$cbError->("Could not get schedule");
				}
			)->get($callurl);
		},

		#could not get a session
		sub {
			$menu = [ { name => 'Failed! - Could not get session' } ];
			$cbError->("Could not get session");
		}
	);

}


sub getStationData {
	my ( $stationUrl, $stationKey, $stationName, $nowOrNext, $cbSuccess, $cbError) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++getStationData");

	if ($nowOrNext eq 'next') {
		$log->error('Next not supported');
		$cbError->(
			{
				url       => $stationUrl,
				stationName => $stationName
			}
		);
		return;
	}


	Plugins::BBCSounds::ProtocolHandler::_getLiveSchedule(
		$stationKey,
		undef,
		sub {
			my $schedule  = shift;
			my $now = time();
			my $progs = $schedule->{data};

			main::INFOLOG && $log->is_info && $log->info("Got Live Schedule for $stationKey ");

			for my $prog (@$progs) {
				my $startTime = str2time($prog->{start});
				my $endTime = str2time($prog->{end});

				if (($now >= $startTime) && ($now <= $endTime)) { # Check the programme for now
					my $title = $prog->{'titles'}->{'primary'};
					if ( defined $prog->{'titles'}->{'secondary'} ) {
						$title = $title . ' - ' . $prog->{'titles'}->{'secondary'};
					}
					if ( defined v->{'titles'}->{'tertiary'} ) {
						$title = $title . ' ' . $prog->{'titles'}->{'tertiary'};
					}
					my $image = $prog->{'image_url'};
					$image =~ s/{recipe}/320x320/;
					my $syn = '';
					if ( defined $prog->{'synopses'}->{'medium'} ) {
						$syn = $prog->{'synopses'}->{'medium'};
					}

					my $networkImage = RF_STATIONIMAGE;

					$networkImage =~ s/{station}/$stationKey/;

					my $result = {
						title =>  $title,
						description => $syn,
						image => $image,
						startTime => $startTime,
						endTime   => $endTime,
						url       => $stationUrl,
						stationName => $stationName,
						stationImage => $networkImage,
					};

					$cbSuccess->($result);
					return;

				}
			}

			$log->error('Failed to retrieve Programme');
			$cbError->($stationUrl);
			return;
		},
		sub {
			#Couldn't get meta data
			$log->error('Failed to retrieve on air text');
			$cbError->(
				{
					url       => $stationUrl,
					stationName => $stationName
				}
			);

		}
	);

	return;
}


1;

