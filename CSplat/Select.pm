use strict;
use warnings;

package CSplat::Select;
use base 'Exporter';

use Date::Manip;

our @EXPORT_OK = qw/is_blacklisted interesting_game/;

use CSplat::Config qw/$UTC_BEFORE $UTC_AFTER/;
use CSplat::Xlog qw/xlog_line desc_game/;
use CSplat::Ttyrec qw/tty_time/;

my $BLACKLIST = 'blacklist.txt';

# Games blacklisted.
my @BLACKLISTED;
my @IPLACES = qw/Tomb Dis Tar Geh Coc Vault Crypt Zot Pan/;

load_blacklist();

sub load_blacklist {
  open my $inf, '<', $BLACKLIST or return;
  while (<$inf>) {
    next unless /\S/ and !/^\s*#/;
    my $game = xlog_line($_);
    push @BLACKLISTED, $game;
  }
  close $inf;
}

sub is_blacklisted {
  my $g = shift;
BLACK_MAIN:
  for my $b (@BLACKLISTED) {
    for my $key (keys %$b) {
      next BLACK_MAIN if $$b{$key} ne $$g{$key};
    }
    return 1;
  }
  undef
}

sub place_prefix {
  my $place = shift;
  return $place if index($place, ':') == -1;
  $place =~ s/:.*//;
  $place
}

sub place_depth {
  my $place = shift;
  my ($depth) = $place =~ /:(\d+)/;
  $depth || 1
}

sub is_interesting_place {
  # We're interested in Zot, Hells, Vaults, Tomb.
  my ($place, $xl) = @_;
  my $prefix = place_prefix($place);
  my $depth = place_depth($place);
  return 1 if $place eq 'Elf:7';
  return 1 if $place =~ /Vault:[78]/;
  return 1 if $place eq 'Blade' && $xl >= 18;
  return 1 if $place eq 'Slime:6';
  return if $prefix eq 'Vault' && $xl < 24;
  ($place =~ "Abyss" && $xl >= 18)
    || $place eq 'Lab'
    || grep($prefix eq $_, @IPLACES)
    # Hive drowning is fun!
    || $place eq 'Hive:4'
}

my @COOL_UNIQUES = qw/Boris Frederick Geryon Xtahua Murray
                      Norris Margery Rupert/;

my %COOL_UNIQUES = map(($_ => 1), @COOL_UNIQUES);

sub interesting_game {
  my $g = shift;

  # Just in case, check for wizmode games.
  return if $g->{wiz};

  my $ktyp = $g->{ktyp};
  return if grep($ktyp eq $_, qw/quitting leaving winning/);

  # No matter how high level, ignore Temple deaths.
  return if $g->{place} eq 'Temple';

  my $start = tty_time($g, 'start');
  my $end = tty_time($g, 'end');

  # Check for the dgl start time bug.
  return if $start ge $end;

  # If the game was in the hazy date range when Crawl was between
  # UTC and local time, skip.
  return if ($end ge $UTC_BEFORE && $end le $UTC_AFTER);

  my $xl = $g->{xl};
  my $place = $g->{place};
  my $killer = $g->{killer} || '';

  my $good =
    $xl >= 25
      || is_interesting_place($place, $xl)
      # High-level player ghost splats.
      || ($xl >= 15 && $killer =~ /'s? ghost/)
      || ($xl >= 15 && $COOL_UNIQUES{$killer});

  if (is_blacklisted($g)) {
    warn "Game is blacklisted: ", desc_game($g), "\n" if $good;
    return;
  }

  $good
}
