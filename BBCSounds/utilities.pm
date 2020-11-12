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

package Plugins::BBCSounds::Utilities;

use warnings;
use strict;

my $log = logger('plugin.bbcsounds');

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


