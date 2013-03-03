#! /usr/bin/perl

use strict;
use warnings;

use File::Path;
use CSplat::Util qw/run_service/;
use CSplat::Config;
use CSplat::TtyrecDir;

# How old a ttyrec directory must be before it will be blown away
my $VACUUM_THRESHOLD_SECONDS = 3 * 24 * 60 * 60; # 72h

main();

sub main {
  run_service('vacuum', \&run_vacuum);
}

sub each_ttyrec_directory(&) {
  my $action = shift;
  my $dir = CSplat::TtyrecDir->new(CSplat::Config::ttyrec_dir());
  $dir->each_player_directory($action);
}

sub file_older_than {
  my ($file, $threshold) = @_;
  my $mtime = (stat $file)[9];
  $mtime && time() - $mtime > $threshold
}

sub newest_ttyrec_needs_vacuum {
  my $dir = shift;
  my @ttyrecs = glob("$dir/*.ttyrec");
  my $newest_mtime;
  for my $ttyrec (@ttyrecs) {
    my $mtime = (stat $ttyrec)[9];
    $newest_mtime = $mtime if !$newest_mtime || $mtime > $newest_mtime;
  }
  return $newest_mtime && time() - $newest_mtime > $VACUUM_THRESHOLD_SECONDS;
}

sub directory_needs_vacuum {
  my $dir = shift;
  my $fetch_timestamp_file = CSplat::TtyrecDir->timestamp_file($dir);
  unless (-f $fetch_timestamp_file) {
    return newest_ttyrec_needs_vacuum($dir);
  }
  return file_older_than($fetch_timestamp_file, $VACUUM_THRESHOLD_SECONDS);
}

sub run_vacuum {
  while (1) {
    each_ttyrec_directory(sub {
      my $dir = shift;
      sleep 1;

      eval {
        CSplat::TtyrecDir->lock_for_vacuum($dir, 2,
                                           sub {
                                             if (directory_needs_vacuum($dir)) {
                                               vacuum_dir($dir);
                                             }
                                           });
      };
      warn "$@" if $@;
    });
    sleep 10;
  }
}

sub vacuum_dir {
  my $dir = shift;
  print "Deleting obsolete directory: $dir\n";
  rmtree($dir) or die "Couldn't delete $dir: $!\n";
}
