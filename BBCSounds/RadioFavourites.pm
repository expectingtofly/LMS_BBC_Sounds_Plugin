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


					my $result = {
						title =>  $title,
						description => $syn,
						image => $image,
						startTime => $startTime,
						endTime   => $endTime,
						url       => $stationUrl,
						stationName => $stationName
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

