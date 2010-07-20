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
our $FETCH_PORT = 49280;

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
  ('un.nethack.nu' =>
   { tz => 'UTC',
     ttypath => 'http://un.nethack.nu/users/$user$/ttyrecs' },
   'sporkhack.org' =>
   { tz => 'UTC',
     ttypath => 'http://sporkhack.com/ttyrec/$user$' },
   'alt.org' =>
   { tz => 'UTC',
     ttypath => 'http://alt.org/nethack/userdata/$user$/ttyrec' }
  );

our %SERVABBREV = (unn => 'http://un.nethack.nu/',
                   spo => 'http://sporkhack.org/',
                   nao => 'http://alt.org/nethack/');

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
  return 'crawl-0.6' if $file =~ /-0.6/;
  return 'trunk' if $file =~ /-trunk/;
  return 'crawl';
}

sub resolve_canonical_game_version {
  my ($path, $g) = @_;
  if ($path =~ /\$game\$/) {
    $path =~ s/\$game\$/ canonical_game_version($g) /ge;
  }
  if ($path =~ /\$user\$/) {
    $path =~ s/\$user\$/ $$g{name} /ge;
  }
  return $path;
}
