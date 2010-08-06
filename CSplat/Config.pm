use strict;
use warnings;

package CSplat::Config;

use base 'Exporter';
our @EXPORT_OK = qw/$DATA_DIR $TTYREC_DIR %SERVMAP
                    $UTC_EPOCH $UTC_BEFORE $UTC_AFTER
                    $FETCH_PORT server_field game_server
                    resolve_canonical_game_version/;

use Carp;
use Date::Manip;

our $DATA_DIR = 'data';
our $TTYREC_DIR = "$DATA_DIR/ttyrecs";

our $UTC_EPOCH = ParseDate("2008-07-30 10:30 UTC");
our $UTC_BEFORE = DateCalc($UTC_EPOCH, "-1 days");
our $UTC_AFTER = DateCalc($UTC_EPOCH, "+2 days");

# Port that the ttyrec fetch server listens on.
our $FETCH_PORT = 41280;

our $RC = 'csplat.rc';

if (-f $RC) {
  open my $inf, '<', $RC;
  while (<$inf>) {
    if (/^\s*fetch_port\s*=\s*(\d+)\s*$/) {
      $FETCH_PORT = int($1);
    }
  }
}
print "Fetch port: $FETCH_PORT\n";

our %SERVMAP =
  ('crawl.akrasiac.org' => { tz => 'EST',
                             dsttz => 'EDT',
                             ttypath => 'http://crawl.akrasiac.org/rawdata' },
   'crawl.develz.org' => { tz => 'CET', dsttz => 'CEST',
                           ttypath => 'http://crawl.develz.org/ttyrecs' },
   'rl.heh.fi' => { tz => 'UTC',
                    ttypath => 'http://rl.heh.fi/$game$/stuff' });

our %SERVABBREV = (cao => 'http://crawl.akrasiac.org/',
                   cdo => 'http://crawl.develz.org/',
                   rhf => 'http://rl.heh.fi/');

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

sub canonical_game_version {
  my $g = shift;
  my $file = $$g{file};

  # Not exactly ideal, but what the hell.
  if ($file =~ /-(\d+(?:[.]\d+)*)/) {
    return "crawl-$1" unless $1 eq '0.5';
  }
  return 'trunk' if $file =~ /-trunk/;
  return 'crawl';
}

sub resolve_canonical_game_version {
  my ($path, $g) = @_;
  if ($path =~ /\$game\$/) {
    $path =~ s/\$game\$/ canonical_game_version($g) /ge;
  }
  return $path;
}
