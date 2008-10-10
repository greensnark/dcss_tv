#! /usr/bin/perl

use strict;
use warnings;

use Getopt::Long;
use CSplat::Config qw/game_server/;
use CSplat::DB qw/%PLAYED_GAMES load_played_games open_db
                  fetch_all_games record_played_game
                  clear_played_games query_one/;
use CSplat::Xlog qw/desc_game desc_game_brief xlog_line xlog_str/;
use CSplat::Ttyrec qw/request_download/;
use CSplat::Select qw/filter_matches make_filter interesting_game/;
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
my @stop_list : shared;

# Fetch mode by default.
GetOptions(\%opt, 'local', 'local-request');

# An appropriately Crawlish number.
my $PLAYLIST_SIZE = 9;

# Socket for splat requests.
my $REQUEST_HOST = 'crawl.akrasiac.org';
my $REQUEST_PORT = 21976;

$REQUEST_HOST = 'localhost' if $opt{'local-request'};

my $REQ = CSplat::Request->new(host => $REQUEST_HOST,
                               port => $REQUEST_PORT);

my $TV = CSplat::Termcast->new(name => 'FooTV',
                               passfile => 'foo.pwd',
                               local => $opt{local});

sub get_game_matching {
  my $g = shift;
  my $filter = make_filter($g);
  my @games = fetch_all_games(splat => undef);
  @games = grep(filter_matches($filter, $_), @games);
  if (@games) {
    return $games[0];
  }
  download_game($g)
}

sub download_game {
  my $g = shift;

  my $start = $g->{start};
  warn "Downloading ttyrecs for ", desc_game($g), "\n";

  $g->{nostart} = 'y';
  $g->{nocheck} = 'y';
  return undef unless request_download($g);
  delete @$g{qw/nostart nocheck/};
  $g
}

sub next_request {
  my $g;
  $g = $REQ->next_request();

  $g->{start} = $g->{rstart};
  $g->{end} = $g->{rend};
  $g->{time} = $g->{rtime};

  $g->{cancel} = 'y' if ($g->{nuke} || '') eq 'y';

  if (($g->{cancel} || '') eq 'y') {
    my $filter = CSplat::Select::make_filter($g);
    $filter = { } if $g->{nuke};
    @queued_playback =
      grep(!CSplat::Select::filter_matches($filter, xlog_line($_)),
           @queued_playback);

    warn "Adding ", desc_game($g), " to stop list\n";
    push @stop_list, xlog_str($g);
    push @queued_fetch, xlog_str($g);
  }
  else {
    push @queued_fetch, xlog_str($g);
    my $game = get_game_matching($g);
    if ($game) {
      $game->{req} = $g->{req};
      push @queued_playback, xlog_str($game, 1);
    } else {
      $g->{failed} = 1;
      push @queued_fetch, xlog_str($g);
    }
  }
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
    $TV->write("\e[1H\e[1;37mLast game played:\e[0m\e[2H\e[1;33m$prev.\e[0m");
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
}

sub cancel_playing_games {
  if (@stop_list) {
    my @stop = @stop_list;
    @stop_list = ();

    my $g = shift;

    if (grep /nuke=y/, @stop) {
      return 'stop';
    }

    my @filters = map(CSplat::Select::make_filter(xlog_line($_)), @stop);

    if (grep(CSplat::Select::filter_matches($_, $g), @filters)) {
      return 'stop';
    }
  }
}

sub request_tv {
  my $last_game;

  open_db();

  my $rcheck = threads->new(\&check_requests);
  $rcheck->detach;

  $TV->callback(\&cancel_playing_games);

 RELOOP:
  while (1) {
    $TV->clear();
    $TV->write("\e[1H");
    if ($last_game) {
      $TV->clear();
      $TV->write("\e[1H");
      $TV->write("\e[1;37mThat was:\e[0m\r\n\e[1;33m");
      $TV->write(desc_game_brief($last_game));
      $TV->write("\e[0m\r\n\r\n");
    }

    $TV->write("Waiting for requests (use !tv on ##crawl to request a game).");
    $TV->write("\r\n\r\n");

    my $slept = 0;
    my $last_msg = 0;
    my $countup;
    while (1) {
      if (@queued_fetch) {
        my $f = xlog_line(shift(@queued_fetch));
        if (($f->{cancel} || '') eq 'y') {
          if ($f->{nuke}) {
            $TV->write("\e[1;35mPlaylist clear by $f->{req}\e[0m\r\n");
          }
          else {
            $TV->write("\e[1;35mCancel by $f->{req}\e[0m\r\n",
                       desc_game_brief($f), "\r\n");
          }
          $last_msg = $slept;
        }
        elsif ($f->{failed}) {
          $TV->write("\e[1;31mFailed to fetch game:\e[0m\r\n",
                     desc_game_brief($f), "\r\n");
          $last_msg = $slept;
        }
        else {
          $TV->write("\e[1;34mRequest by $$f{req}:\e[0m\r\n",
                     desc_game_brief($f), "\r\n");
          $TV->write("\r\nPlease wait, fetching game...\r\n");
          undef $last_msg;
        }
        $countup = 1;
      }

      if (@queued_playback) {
        my @copy = map(xlog_line($_), @queued_playback);
        tv_show_playlist(\@copy, $last_game);
        sleep 4 if $slept < 2;
        last;
      }

      ++$slept if $countup;
      next RELOOP if $last_msg && $slept - $last_msg > 20;
      sleep 1;
    }

    my $line = shift(@queued_playback);
    if ($line) {
      my $g = xlog_line($line);
      $TV->play_game($g);
      $last_game = $g;
    }
  }
}

request_tv();
