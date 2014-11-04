use strict;
use warnings;

package CSplat::Config;

use Carp;
use Date::Manip;
use YAML::Any;
use CSplat::TtyrecSource;
use CSplat::TimestampSource;
use Date::Manip;

our $DATA_DIR = 'data';
our $TTYREC_DIR = "$DATA_DIR/ttyrecs";

our %CFG = %{YAML::Any::LoadFile('config/sources.yml')};
my %SERVABBREV = map(($_->{name} => $_), @{$CFG{sources}});

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

sub fetch_port {
  $FETCH_PORT
}

sub data_dir {
  $DATA_DIR
}

sub ttyrec_dir {
  $TTYREC_DIR
}

sub server_cfg {
  my $src = shift;
  $SERVABBREV{$src} or die "No ttyrec server known for source '$src'\n"
}

sub server_base {
  (server_cfg(shift) || {})->{base}
}

sub server_hostname {
  my $base = server_base(shift);
  return unless $base;
  $base =~ qr{https?://([^/]+)} && $1
}

sub game_server {
  my $g = shift;
  my $src = $g->{src};
  server_hostname($src)
}

sub game_server_field {
  my ($g, $field) = @_;
  server_cfg($$g{src})->{$field}
}

sub game_server_list_field {
  my ($g, $field) = @_;
  my $value = game_server_field($g, $field);
  if ($value && !ref($value)) {
    return ($value);
  }
  else {
    return @$value;
  }
}

sub game_server_ttyrec_source {
  my $g = shift;
  CSplat::TtyrecSource->new(game_server_field($g, 'ttyrecs'))->resolve($g)
}

sub game_server_timestamp_source {
  my $g = shift;
  CSplat::TimestampSource->new(game_server_field($g, 'timestamps'))->resolve($g)
}

sub game_server_utc_epoch {
  my $g = shift;
  my $epoch = game_server_field($g, 'utc-epoch');
  return unless $epoch;
  ParseDate($epoch)
}

sub game_server_timezone {
  my ($g, $tz) = @_;
  game_server_field($g, 'timezones')->{$tz}
}

sub game_server_rate_limit {
  my $g = shift;
  game_server_field($g, 'rate-limit')
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

1
