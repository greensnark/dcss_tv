#! /usr/bin/perl

use strict;
use warnings;

use Getopt::Long;
use CSplat::Config qw/game_server/;
use CSplat::DB qw/%PLAYED_GAMES load_played_games open_db
                  fetch_all_games record_played_game
                  clear_played_games query_one/;
use CSplat::Xlog qw/desc_game desc_game_brief xlog_line xlog_str/;
use CSplat::Ttyrec qw/fetch_ttyrecs record_game clear_cached_urls/;
use CSplat::Select qw/filter_matches make_filter/;
use CSplat::Seek qw/tty_frame_offset/;
use CSplat::Termcast;
use CSplat::Request;
use Term::TtyRec::Plus;
use IO::Socket::INET;
use Date::Manip;
use Fcntl qw/SEEK_SET/;

use threads;
use threads::shared;

my %opt;

my @queued_fetch : shared;
my @queued_playback : shared;

# Fetch mode by default.
GetOptions(\%opt, 'local');

# An appropriately Crawlish number.
my $PLAYLIST_SIZE = 9;

# Socket for splat requests.
my $REQUEST_HOST = 'crawl.akrasiac.org';
my $REQUEST_PORT = 21976;

$REQUEST_HOST = 'localhost' if $opt{local};

my $REQ = CSplat::Request->new(host => $REQUEST_HOST,
                               port => $REQUEST_PORT);

my $TV = CSplat::Termcast->new(name => 'FooTV',
                               passfile => 'foo.pwd',
                               local => $opt{local});

sub get_game_matching {
  my $g = shift;
  my $filter = make_filter($g);
  my @games = fetch_all_games();
  @games = grep(filter_matches($filter, $_), @games);
  return $games[0] if @games;

  download_game($g)
}

sub download_game {
  my $g = shift;

  my $start = $g->{start} = $g->{rstart};
  $g->{end} = $g->{rend};
  warn "Downloading ttyrecs for ", desc_game($g), "\n";

  # Don't use start time when looking for ttyrecs.
  delete $g->{start};
  return unless fetch_ttyrecs($g, 1);
  $g->{start} = $start;
  record_game($g);
  tty_frame_offset($g, 1);
  $g
}

sub next_request {
  my $g;
  do {
    $g = $REQ->next_request();
  } while ($g->{splat} eq 'y');
  clear_cached_urls();

  push @queued_fetch, xlog_str($g);
  my $game = get_game_matching($g);
  push @queued_playback, xlog_str($game, 1) if $game;
}

sub check_requests {
  open_db();
  while (1) {
    next_request();
    sleep 1;
  }
}

sub tv_show_playlist {
  my ($rplay, $prev) = @_;

  $TV->clear();
  if ($prev) {
    $prev = desc_game_brief($prev);
    $TV->write("\e[1H\e[1;37mThat was:\e[0m\e[2H\e[1;33m$prev.\e[0m");
  }

  my $pos = 1 + ($prev ? 3 : 0);
  $TV->write("\e[$pos;1H\e[1;37mComing up:\e[0m");
  $pos++;

  my $first = 1;
  my @display = @$rplay;
  if (@display > $PLAYLIST_SIZE) {
    @display = @display[0 .. ($PLAYLIST_SIZE - 1)];
  }
  for my $game (@display) {
    # Move to right position:
    $TV->write("\e[$pos;1H",
               $first? "\e[1;34m" : "\e[0m",
               desc_game_brief($game));
    $TV->write("\e[0m") if $first;
    undef $first;
    ++$pos;
  }

  sleep(5);
}

sub request_tv {
  my $last_game;

  my $rcheck = threads->new(\&check_requests);
  $rcheck->detach;

  sleep 1;
  open_db();

  $TV->clear();
  while (1) {
    $TV->write("\e[1H");

    $TV->write("Waiting for requests (use !tv on ##crawl to request a game).");
    $TV->write("\r\n\r\n");

    while (1) {
      if (@queued_playback) {
        my @copy = map(xlog_line($_), @queued_playback);
        tv_show_playlist(\@copy, $last_game);
        sleep 4;
        last;
      }

      if (@queued_fetch) {
        my $f = xlog_line(shift(@queued_fetch));
        print "Request by $$f{req}:\r\n", desc_game_brief($f), "\r\n";
      }

      sleep 1;
    }

    my $line = shift(@queued_playback);
    my $g = xlog_line($line);
    $TV->play_game($g);
    $last_game = $g;
  }
}

request_tv();
