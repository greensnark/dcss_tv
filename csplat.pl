#! /usr/bin/perl

# C-SPLAT by greensnark.
# Based on TermCastTv 1.2 by Eidolos.

use strict;
use warnings;
use File::Path;
use Date::Manip;
use Getopt::Long;
use Fcntl qw/SEEK_SET/;

use CSplat::DB qw/open_db fetch_all_games exec_query
                  query_one in_transaction purge_log_offsets/;
use CSplat::Config qw/$DATA_DIR/;
use CSplat::Ttyrec qw/$TTYREC_DIR url_file fetch_ttyrecs
                      update_fetched_games fetch_url record_game
                      clear_cached_urls ttyrec_path/;
use CSplat::Xlog qw/xlog_line desc_game/;
use CSplat::Select qw/interesting_game/;

# Overall strategy:
# * Fetch logfiles.
# * Scan logfiles to pick games. Keep track of logfile offsets.
# * For selected games, check server to see if we have ttyrecs.
# * Grab ttyrecs and drop them in ttyrec directory.
# * Spawn tv once we have X games' worth of ttyrec.
# * As we load more games, write them into ttyrec dir, update
#   index card for ttyrecs (with game info).
# * Strip ibm gfx as we play.
#
# Todo:
# * Overlay to show how much time left?

my $FETCH_ONLY = 0;

my @LOG_URLS = ('http://crawl.akrasiac.org/allgames.txt',
                'http://crawl.akrasiac.org/logfile04',
                'http://crawl.develz.org/allgames-old.txt',
                'http://crawl.develz.org/allgames-rel.txt',
                'http://crawl.develz.org/allgames-svn.txt');

my @LOG_FILES = map { m{.*/(.*)} } @LOG_URLS;

my %opt;

# Fetch mode by default.
GetOptions(\%opt, 'rescan', 'local', 'migrate',
           'sanity-check', 'sanity-fix');

sub seek_log {
  my $url = shift;
  my $file = log_path($url);
  open my $inf, '<', $file or die "Can't read $file: $!\n";
  my $offset = query_one("SELECT MAX(offset) FROM logplace WHERE logfile = ?",
                         $url);
  if ($offset) {
    print "Seeking to $offset in $file\n";
    seek $inf, $offset, SEEK_SET
  }
  $inf
}

sub read_log {
  my ($fh, $log) = @_;
  my $pos = tell $fh;
  my $line = <$fh>;
  return unless defined($line) && $line =~ /\n$/;

  chomp $line;
  my $fields = xlog_line($line);
  $fields->{offset} = $pos;
  $fields->{src} = $log;
  $fields
}

sub fetch {
  check_dirs();
  update_fetched_games();
  rescan_games() if $opt{rescan};
  while (1) {
    fetch_logs(@LOG_URLS);
    trawl_games();
    print "Sleeping between log scans...\n";
    sleep 600;
    clear_cached_urls();
  }
}

sub sanity_check_pred {
  my ($g, $cond, $msg) = @_;
  if ($cond) {
    warn "\n$msg: ", desc_game($g), "\n";
    if ($opt{'sanity-fix'}) {
      delete_game($g);
    }
  }
  $cond
}

# Goes through all the games we've flagged in the DB, deleting those
# that don't match interesting_game.
sub rescan_games {
  my @games = fetch_all_games();

  in_transaction(
    sub {
      for my $g (@games) {
        if (!interesting_game($g)) {
          delete_game($g);
        }
      }

      purge_log_offsets();
      } );
}

# Check if all the ttyrecs we have are death ttyrecs. If sanity-fix is set,
# will also delete games that have no death ttyrecs.
sub sanity_check {
  my @games = fetch_all_games();
  print "Running sanity-check";
  print ", will fix errors." if $opt{'sanity-fix'};
  print "\n";

  # Turn on autoflush.
  local $| = 1;

  my $gcount = 0;
  for my $g (@games) {
    ++$gcount;
    print "Sanity checking $gcount / ", scalar(@games), "\r";

    my @ttyrecs = split / /, $g->{ttyrecs};

    sanity_check_pred($g, !is_death_ttyrec($g, $ttyrecs[-1]),
                      "Game has no death ttyrec")
      ||

        sanity_check_pred($g, ttyrecs_out_of_time_bounds($g),
                          "Game has out-of-range ttyrecs")
      ||
        sanity_check_pred($g, is_blacklisted($g),
                          "Game is blacklisted");
  }
  print "\n";
}

sub migrate_paths {
  my @games = fetch_all_games();
  for my $g (@games) {
    print "Processing ", desc_game($g), "\n";

    for my $ttyrec (split / /, $g->{ttyrecs}) {
      my $old_path = "$TTYREC_DIR/" . url_file($ttyrec);
      my $new_path = ttyrec_path($g, $ttyrec);
      if (-f $old_path) {
        print "Found ttyrec at $old_path, moving it to $new_path\n";
        rename $old_path, $new_path or die "Couldn't rename $old_path: $!\n";
      }
    }
  }
}

sub delete_game {
  my $g = shift;
  print "Discarding game: ", desc_game($g), "\n";

  # There's a distinct time window here where we could inconvenience a parallel
  # tv player script, but that can't be helped.
  for my $ttyrec (split / /, $g->{ttyrecs}) {
    my $file = ttyrec_path($g, $ttyrec);
    if (-f $file) {
      print "Deleting $file\n";
      unlink $file;
    }
  }
  exec_query("DELETE FROM ttyrec WHERE id = ?", $g->{id});
}

sub check_dirs {
  mkpath( [ $DATA_DIR, $TTYREC_DIR ] );
}

sub create_tables {
  my $dbh = shift;
  print "Setting up splat database\n";

  my @ddl_lines = (
                   <<'T1',
  CREATE TABLE logplace (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     logfile TEXT,
     offset INTEGER
  );
T1
                   <<'T2',
  CREATE INDEX loff ON logplace (logfile, offset);
T2
                   <<'T3',
  CREATE TABLE ttyrec (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     logrecord TEXT,
     ttyrecs TEXT
  );
T3
                   <<'T4',
  CREATE TABLE played_games (
     ref_id INTEGER,
     FOREIGN KEY (ref_id) REFERENCES ttyrec (id)
  );
T4
                   );
  for my $line (@ddl_lines) {
    $dbh->do($line) or die "Can't create table schema!";
  }
}

sub log_path {
  my $url = shift;
  $DATA_DIR . "/" . url_file($url)
}

sub fetch_logs {
  my @logs = @_;

  for my $log (@logs) {
    fetch_url($log, log_path($log));
  }
}

sub record_log_place {
  my ($log, $game) = @_;
  exec_query("INSERT INTO logplace (logfile, offset)
              VALUES (?, ?)",
             $log, $game->{offset});
  # Discard old records.
  exec_query("DELETE FROM logplace
              WHERE logfile = ? AND offset < ?",
             $log, $game->{offset});
}

sub count_existing_games {
  query_one("SELECT COUNT(*) FROM ttyrec")
}

#######################################################################

sub trawl_games {
  my $lines = 0;
  my $games = 0;
  my $existing_games = count_existing_games();

  for my $log (@LOG_URLS) {
    # Go to last point that we processed.
    my $fh = seek_log($log);
    while (my $game = read_log($fh, $log)) {

      my $good_game = interesting_game($game) && fetch_ttyrecs($game);
      $games++ if $good_game;

      in_transaction(sub {
                       record_game($game) if $good_game;
                       record_log_place($log, $game)
                     });

      if (!(++$lines % 100)) {
        my $total = $games + $existing_games;
        print "Scanned $lines lines, found $total interesting games\n";
      }
    }
  }
}

open_db();
if ($opt{migrate}) {
  migrate_paths();
}
elsif ($opt{'sanity-check'}) {
  sanity_check();
}
else {
  fetch();
}
