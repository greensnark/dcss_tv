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
                  query_one in_transaction purge_log_offsets
                  tty_delete_frame_offset check_dirs/;
use CSplat::Config qw/$DATA_DIR $TTYREC_DIR/;
use CSplat::Ttyrec qw/url_file fetch_url ttyrec_path is_death_ttyrec
                      ttyrecs_out_of_time_bounds request_download/;
use CSplat::Xlog qw/xlog_line desc_game/;
use CSplat::Select qw/interesting_game is_blacklisted filter_matches/;
use CSplat::Seek qw/tty_frame_offset set_buildup_size/;

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
           'sanity-check', 'sanity-fix', 'filter=s@',
           're-seek=f', 'default-seek=f', 'purge');

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
  rescan_games() if $opt{rescan};
  while (1) {
    fetch_logs(@LOG_URLS);
    trawl_games();
    print "Sleeping between log scans...\n";
    sleep 600;
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
  my @games = fetch_all_games(splat => 'y');

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

sub purge_nonsplats {
  print "Purging non-splat games...\n";
  my @games = fetch_all_games(splat => '');
  for my $g (@games) {
    delete_game($g);
  }

  print "Purging milestones...\n";
  @games = fetch_all_games(splat => 'm');
  for my $g (@games) {
    delete_game($g);
  }
}

sub fixup_game_table {
  my $rows =
    CSplat::DB::exec_query_all(
                               'SELECT src, player, gtime, logrecord, id,
                                       ttyrecs
                                FROM games');

  my @fixup;
  for my $row (@$rows) {
    if (!$row->[0] || !$row->[1] || !$row->[2]) {
      push @fixup, [ $row->[3], $row->[4] ];
    }
  }

  for my $row (@fixup) {
    my $xlog = $row->[0];
    my $id = $row->[1];
    my $g = xlog_line($xlog);

    print "Fixing null fields for game $id\n";
    CSplat::DB::exec_query('UPDATE games SET src = ?, player = ?, gtime = ?
                            WHERE id = ?',
                           $g->{src}, $g->{name}, $g->{end} || $g->{time},
                           $id);
  }

  # Register all unregistered ttyrecs.
  for my $row (@$rows) {
    my $ttyrecs = $row->[5];
    my $g = xlog_line($row->[3]);
    for my $ttyrec (split ' ', $ttyrecs) {
      CSplat::Ttyrec::check_register_ttyrec($g, $ttyrec);
    }
  }
}

# Check if all the ttyrecs we have are death ttyrecs. If sanity-fix is set,
# will also delete games that have no death ttyrecs.
sub sanity_check {
  fixup_game_table();

  my @games = fetch_all_games(splat => 'y');

  if ($opt{filter}) {
    my @chosen;

    for my $filter (@{$opt{filter}}) {
      my $xlogfilter = xlog_line($filter);
      push @chosen, grep(filter_matches($xlogfilter, $_), @games);
    }
    @games = @chosen;
  }

  if ($opt{'re-seek'}) {
    my $off = $opt{'re-seek'};
    set_buildup_size($off);
  }

  if ($opt{'default-seek'}) {
    set_default_playback_multiplier($opt{'default-seek'});
  }

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

    next if $g->{deleted};

    tty_delete_frame_offset($g) if $opt{'re-seek'};

    # Find and save the offset and frame into this ttyrec where
    # playback starts.
    tty_frame_offset($g, 1);
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

  # Don't delete ttyrecs yet - they could be used by multiple entries.

  exec_query("DELETE FROM games WHERE id = ?", $g->{id});
  $g->{deleted} = 'y';
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

      my $good_game =
        interesting_game($game, 1) && do {
          print "Downloading ", desc_game($game), "\n";
          request_download($game);
        };
      $games++ if $good_game;

      record_log_place($log, $game);

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
elsif ($opt{purge}) {
  purge_nonsplats();
}
else {
  fetch();
}
