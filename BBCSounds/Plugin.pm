package Plugins::BBCSounds::Plugin;

use warnings;
use strict;

use base qw(Slim::Plugin::OPMLBased);

use Slim::Utils::Strings qw(string);
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Plugins::BBCSounds::BBCSoundsFeeder;
use Plugins::BBCSounds::ProtocolHandler;

my $log = Slim::Utils::Log->addLogCategory(
    {
        'category'     => 'plugin.bbcsounds',
        'defaultLevel' => 'ERROR',
        'description'  => getDisplayName(),
    }
);

sub initPlugin {
    my $class = shift;

    $class->SUPER::initPlugin(
        feed   => \&Plugins::BBCSounds::BBCSoundsFeeder::toplevel,
        tag    => 'bbcsounds',
        menu   => 'radios',
        is_app => $class->can('nonSNApps') ? 1 : undef,
        weight => 1,
    );

    if ( !$::noweb ) {
        require Plugins::BBCSounds::Settings;
        Plugins::BBCSounds::Settings->new;
    }

    return;
}

sub getDisplayName { return 'PLUGIN_BBCSOUNDS'; }

1;
