#! /usr/bin/perl

use strict;
use warnings;

use Getopt::Long;
use CSplat::Config qw/game_server/;
use CSplat::DB qw/%PLAYED_GAMES load_played_games open_db
                  fetch_all_games record_played_game
                  clear_played_games query_one/;
use CSplat::Xlog qw/desc_game desc_game_brief xlog_line xlog_str/;
use CSplat::Ttyrec qw/$TTYRMINSZ $TTYRMAXSZ $TTYRDEFSZ ttyrec_path
                      ttyrec_file_time tty_time tv_frame_strip/;
use CSplat::Select qw/filter_matches make_filter/;
use CSplat::Seek qw/tty_frame_offset/;
use CSplat::Termcast;
use CSplat::Request;

use Term::TtyRec::Plus;
use IO::Socket::INET;
use Date::Manip;

use threads;
use threads::shared;

# An appropriately Crawlish number.
my $PLAYLIST_SIZE = 9;

# Socket for splat requests.
my $REQUEST_HOST = 'crawl.akrasiacrasiac.org';
my $REQUEST_PORT = 21976;

my $REQ = CSplat::Request->new(host => $REQUEST_HOST,
                               port => $REQUEST_PORT);

# Games requested for TV.
my $t_requested_games : shared = '';

my %opt;

# Fetch mode by default.
GetOptions(\%opt, 'local', 'filter=s');

$REQUEST_HOST = 'localhost' if $opt{local};

############################  TV!  ####################################

my $SERVER      = '213.184.131.118'; # termcast server (probably don't change)
my $PORT        = 31337;             # termcast port (probably don't change)
my $NAME        = 'C_SPLAT';         # name to use on termcast
my $thres       = 3;                 # maximum sleep secs on a ttyrec frame
my @ALLGAMES;
my @TVGAMES;

my $PWFILE = 'tv.pwd';

my $TV = CSplat::Termcast->new(name => $NAME,
                               passfile => $PWFILE,
                               local => $opt{local}
                              );

sub scan_ttyrec_list {
  @TVGAMES = @ALLGAMES = fetch_all_games();
  if ($opt{filter}) {
    my $filter = xlog_line($opt{filter});
    @TVGAMES = grep(filter_matches($filter, $_), @TVGAMES);
  }

  die "No games to play!\n" unless @TVGAMES;
}

sub pick_random_unplayed {
  @TVGAMES = grep(!$PLAYED_GAMES{$_->{id}}, @TVGAMES);
  unless (@TVGAMES) {
    clear_played_games();
    scan_ttyrec_list();
  }
  die "No games?" unless @TVGAMES;
  my $game = $TVGAMES[int(rand(@TVGAMES))];
  record_played_game($game);
  $game
}

# If there's more than one waiting request from one nick, take only the last
# request.
sub squash_splat_requests {
  my $pref = shift;
  my @requests = grep($_->{req}, @$pref);

  if (@requests) {
    my $orig = scalar(@requests);
    my %dupes;
    @requests = reverse(grep(!$dupes{$_->{req}}++, reverse(@requests)));

    my %ids;
    $ids{$_->{id}} = 1 for @requests;

    if (@requests < $orig) {
      @$pref = grep(!$_->{req} || $ids{$_->{id}}, @$pref);
    }
  }
}

sub build_playlist {
  my $pref = shift;

  # Check for new ttyrecs in the DB.
  scan_ttyrec_list();

  my @requested_games = get_requested_games();

  if (@requested_games) {
    # Any requested games go to the top of the playlist.
    unshift @$pref, @requested_games;

    # And then we eliminate duplicates.
    my %ids;
    @$pref = grep(!$ids{$_->{id}}++, @$pref);

    squash_splat_requests($pref);
  }

  # Strip games that were in the playlist, but went awol while we were
  # playing the last game.
  @$pref = grep(tv_game_exists($_), @$pref);

  while (@$pref < $PLAYLIST_SIZE) {
    push @$pref, pick_random_unplayed();
  }
}

sub run_tv {
  load_played_games();
  run_splat_request_thread();

  my $old;
  my @playlist;
  while (1) {
    build_playlist(\@playlist);

    die "No games to play?" unless @playlist;

    tv_show_playlist(\@playlist, $old);
    $old = shift @playlist;
    $TV->play_game($old);
  }
}

# Perform a last-minute check to see if the game is still there.
sub tv_game_exists {
  my $g = shift;
  query_one("SELECT COUNT(*) FROM ttyrec WHERE id = ?", $g->{id})
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

sub find_requested_games {
  my $games = shift;

  my @games;

  my @requests = map(xlog_line($_), grep(/\S/, split(/\n/, $games)));
  warn "Got ", scalar(@requests), " new requests\n";

  for my $g (@requests) {
    delete $g->{start} if $g->{start} gt $g->{end};
    warn "Looking for games matching ", xlog_str($g), "\n";

    my $filter = make_filter($g);
    my @matches = grep(filter_matches($filter, $_), @ALLGAMES);

    warn "Found ", scalar(@matches), " games for request: ", xlog_str($g), "\n";

    $_->{req} = $g->{req} for @matches;
    push(@games, @matches);
  }

  # Toss duplicate requests.
  my %seen_ids;
  grep(!$seen_ids{$_->{id}}++, @games)
}

sub get_requested_games {
  my $games;
  {
    lock($t_requested_games);
    ($games) = $t_requested_games =~ /(.*\n)/s;
    $t_requested_games =~ s/(.*\n)//;
  }

  return unless $games;
  find_requested_games($games)
}

sub check_splat_requests {
  while (my $game = $REQ->next_request_line()) {
    my ($g) = $game =~ /^\d+ (.*)/;
    next unless $g;
    chomp $g;
    {
      lock($t_requested_games);
      $t_requested_games .= "$g\n";
      warn "Request: $g\n";
    }
  }
}

sub run_splat_request_thread {
  my $t = threads->new(\&check_splat_requests);
  $t->detach;
}

sub delta_seconds {
  my $delta = shift;
  Delta_Format($delta, 0, "%sh")
}

sub calc_perc {
  my ($num, $den) = @_;
  return "0.0" if $den == 0;
  sprintf "%.2f%%", ($num * 100 / $den)
}

open_db();
run_tv();
