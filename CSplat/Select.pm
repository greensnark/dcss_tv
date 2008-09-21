use strict;
use warnings;

package CSplat::Select;
use base 'Exporter';

use Date::Manip;

our @EXPORT_OK = qw/is_blacklisted interesting_game filter_matches/;

use CSplat::Config qw/$UTC_BEFORE $UTC_AFTER/;
use CSplat::Xlog qw/xlog_line desc_game/;
use CSplat::Ttyrec qw/tty_time/;

my $BLACKLIST = 'blacklist.txt';
my $SPLAT_HOME = $ENV{SPLAT_HOME};
$BLACKLIST = "$SPLAT_HOME/$BLACKLIST" if $SPLAT_HOME;

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

sub field_mangle {
  my ($field, $v) = @_;
  return $v unless defined $v;
  if ($field eq 'start' || $field eq 'end') {
    $v =~ s/[SD]$//;
  }
  $v
}

sub filter_matches {
  my ($filter, $g) = @_;
  for my $key (keys %$filter) {
    return if field_mangle($key, $$filter{$key}) ne
       field_mangle($key, ($$g{$key} || ''));
  }
  1
}

sub is_blacklisted {
  my $g = shift;
  scalar(grep(filter_matches($_, $g), @BLACKLISTED))
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
  my ($g, $place, $xl) = @_;
  my $killer = $g->{killer};
  my $prefix = place_prefix($place);
  my $depth = place_depth($place);
  my $ktyp = $g->{ktyp};
  return 1 if $place eq 'Lab' && $xl >= 16 && $ktyp ne 'starvation';
  return 1 if $place eq 'Elf:7';
  return 1 if $place =~ /Vault:[3-8]/;
  return 1 if $place eq 'Blade' && $xl >= 18;
  return 1 if $place eq 'Slime:6';
  return if $prefix eq 'Vault' && $xl < 24;
  ($place =~ "Abyss" && $xl >= 18)
    || grep($prefix eq $_, @IPLACES)
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
    $xl >= 22
      || is_interesting_place($g, $place, $xl)
      # High-level player ghost splats.
      || ($xl >= 15 && $killer =~ /'s? ghost/)
      || ($xl >= 15 && $COOL_UNIQUES{$killer});

  if (is_blacklisted($g)) {
    warn "Game is blacklisted: ", desc_game($g), "\n" if $good;
    return;
  }

  $good
}