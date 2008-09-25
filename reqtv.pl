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
use CSplat::Seek qw/tty_frame_offset set_buildup_size/;
use CSplat::Termcast;
use CSplat::Request;
use Term::TtyRec::Plus;
use IO::Socket::INET;
use Date::Manip;
use Fcntl qw/SEEK_SET/;

my %opt;

# Fetch mode by default.
GetOptions(\%opt, 'local');

set_buildup_size(4);

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
  download_game($g);
}

sub download_game {
  my $g = shift;

  $g->{start} = $g->{rstart};
  $g->{end} = $g->{rend};
  warn "Downloading ttyrecs for ", desc_game($g), "\n";
  return unless fetch_ttyrecs($g, 1);
  record_game($g);
  tty_frame_offset($g, 1);
  $g
}

sub request_tv {
  my $last_game;

  $TV->clear();
  while (1) {
    $TV->write("\e[1H");
    if ($last_game) {
      $TV->write("\e[1;37mThat was:\e[0m\n\e[1;33m");
      $TV->write(desc_game_brief($last_game));
      $TV->write("\e[0m\n\n");
    }
    $TV->write("Waiting for requests (use !tv on ##crawl to request a game).");
    $TV->write("\n\n");

    my $g;
    do {
      $g = $REQ->next_request();
    } while ($g->{splat} eq 'y');

    clear_cached_urls();
    $TV->write("Request from $g->{req}:\n", desc_game_brief($g), "\n\n");
    my $game = get_game_matching($g);

    unless ($game) {
      $TV->write("No games found matching " . xlog_str($g) . "\n");
    } else {
      $TV->play_game($game);
      $last_game = $game;
    }
  }
}

open_db();
request_tv();
