use strict;
use warnings;

package CSplat::TtyTime;

use lib '..';
use base 'Exporter';

our @EXPORT_OK = qw/tty_tz_time tty_time/;

use CSplat::Config;
use CSplat::Xlog qw/fix_crawl_time/;
use Date::Manip;

sub tty_tz_time {
  my ($g, $time) = @_;
  my $dst = $time =~ /D$/;
  $time =~ s/[DS]$//;
  my $tz = game_server_timezone($g, $dst? 'D' : 'S');
  ParseDate("$time$tz")
}

sub tty_time {
  my ($g, $which) = @_;

  my $raw = $g->{$which};
  return unless $raw;

  my $time = fix_crawl_time($raw);
  (my $stripped = $time) =~ s/[DS]$//;

  # First parse it as UTC.
  my $parsed = ParseDate("$stripped+0000");

  my $utc_epoch = CSplat::Config::game_server_utc_epoch($g);
  # If it was before the UTC epoch, parse it as the appropriate local time.
  $parsed = tty_tz_time($g, $time) if $utc_epoch && $parsed lt $utc_epoch;
  $parsed
}

1
