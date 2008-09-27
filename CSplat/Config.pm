use strict;
use warnings;

package CSplat::Config;

use base 'Exporter';
our @EXPORT_OK = qw/$DATA_DIR $TTYREC_DIR %SERVMAP
                    $UTC_EPOCH $UTC_BEFORE $UTC_AFTER
                    $FETCH_PORT server_field game_server/;

use Carp;
use Date::Manip;

our $DATA_DIR = 'data';
our $TTYREC_DIR = "$DATA_DIR/ttyrecs";

our $UTC_EPOCH = ParseDate("2008-07-30 10:30 UTC");
our $UTC_BEFORE = DateCalc($UTC_EPOCH, "-1 days");
our $UTC_AFTER = DateCalc($UTC_EPOCH, "+2 days");

# Port that the ttyrec fetch server listens on.
our $FETCH_PORT = 41280;

our %SERVMAP =
  ('crawl.akrasiac.org' => { tz => 'EST',
                             dsttz => 'EDT',
                             ttypath => 'http://crawl.akrasiac.org/rawdata' },
   'crawl.develz.org' => { tz => 'CET', dsttz => 'CEST',
                           ttypath => 'http://crawl.develz.org/ttyrecs' });

our %SERVABBREV = (cao => 'http://crawl.akrasiac.org/',
                   cdo => 'http://crawl.develz.org/');

sub game_server {
  my $g = shift;
  my $src = $g->{src};
  $src = $SERVABBREV{$src} if $src =~ /^\w+$/;
  my ($server) = $src =~ m{^http://(.*?)/};
  confess "No server in $src\n" unless $server;
  $server
}

sub server_field {
  my ($g, $field) = @_;
  my $server = game_server($g);

  my $sfield = $SERVMAP{$server} or die "Unknown server: $server\n";
  $sfield->{$field}
}
