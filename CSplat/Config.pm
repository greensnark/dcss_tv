use strict;
use warnings;

package CSplat::Config;

use base 'Exporter';
our @EXPORT_OK = qw/$DATA_DIR $TTYREC_DIR %SERVMAP
                    $UTC_EPOCH $UTC_BEFORE $UTC_AFTER
                    $FETCH_PORT server_field server_list_field game_server
                    resolve_player_directory/;

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
  ('crawl.akrasiac.org' => {
     tz => 'EST',
     dsttz => 'EDT',
     ttypath => ['http://termcast.develz.org/cao/ttyrecs/$player$',
                 'http://crawl.akrasiac.org/rawdata/$player$'],
     timestamp_path => ['http://crawl.akrasiac.org/rawdata/$player$']
   },
   'crawl.develz.org' => {
     tz => 'CET', dsttz => 'CEST',
     ttypath => ['http://termcast.develz.org/ttyrecs/$player$',
                 'http://crawl.develz.org/ttyrecs/$player$' ],
     timestamp_path => ['http://crawl.develz.org/morgues/trunk/$player$',
                        'http://crawl.develz.org/morgues/0.10/$player$',
                        'http://crawl.develz.org/morgues/0.9/$player$',
                        'http://crawl.develz.org/morgues/0.8/$player$',
                        'http://crawl.develz.org/morgues/0.7/$player$',
                        'http://crawl.develz.org/morgues/0.6/$player$',
                        'http://crawl.develz.org/morgues/0.5/$player$',
                        'http://crawl.develz.org/morgues/0.4/$player$']
   },
   'light.bitprayer.com' => {
     http_fetch_only => 1,
     tz => 'UTC', dsttz => 'UTC',
     ttypath => ['http://light.bitprayer.com/userdata/$player$/ttyrec'],
     timestamp_path => ['http://light.bitprayer.com/userdata/$player$/morgue']
   },
   'crawl.s-z.org' => {
     http_fetch_only => 1,
     tz => 'EST', dsttz => 'EDT',
     ttypath => ['http://dobrazupa.org/ttyrec/$player$'],
     timestamp_path => ['http://dobrazupa.org/morgue/$player$']
   },
);

our %SERVABBREV = (cao  => 'http://crawl.akrasiac.org/',
                   cdo  => 'http://crawl.develz.org/',
                   rhf  => 'http://rl.heh.fi/',
                   lbc  => 'http://light.bitprayer.com/',
                   cszo => 'http://crawl.s-z.org/');

sub game_server {
  my $g = shift;
  my $src = $g->{src};
  $src = $SERVABBREV{$src} if $src =~ /^\w+$/;
  my ($server) = $src =~ m{^http://(.*?)/};
  confess "No server in $src\n" unless $server;
  $server
}

sub server_config {
  my $server = shift;
  $SERVMAP{$server}
}

sub server_field {
  my ($g, $field) = @_;
  my $server = game_server($g);
  my $sfield = server_config($server);
  $sfield->{$field}
}

sub http_fetch_only {
  my $server = shift;
  my $server_config = server_config($server);
  $server_config && $server_config->{http_fetch_only}
}

sub server_list_field {
  my ($g, $field) = @_;
  my $value = server_field($g, $field);
  if ($value && !ref($value)) {
    return ($value);
  }
  else {
    return @$value;
  }
}

sub canonical_game_version {
  my $g = shift;
  my $file = $$g{file};

  return "sprint" if $file =~ /rhf.*-spr/;

  # Not exactly ideal, but what the hell.
  if ($file =~ /-(\d+(?:[.]\d+)*)/) {
    return "crawl-$1" unless $1 eq '0.5';
  }
  return 'trunk' if $file =~ /-trunk/;
  return 'crawl';
}

sub resolve_game_field {
  my ($field, $g) = @_;
  return canonical_game_version($g) if $field eq 'game';
  $field = 'name' if $field eq 'player';
  $$g{$field}
}

sub resolve_player_directory {
  my ($url, $g) = @_;
  $url =~ s/\$(\w+)\$/ resolve_game_field($1, $g) /ge;
  $url
}

1
