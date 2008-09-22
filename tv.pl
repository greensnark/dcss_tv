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
use CSplat::Select qw/filter_matches/;
use CSplat::Seek qw/tty_frame_offset clear_screen/;
use Term::TtyRec::Plus;
use IO::Socket::INET;
use Date::Manip;
use Fcntl qw/SEEK_SET/;

use threads;
use threads::shared;

# An appropriately Crawlish number.
my $PLAYLIST_SIZE = 9;

# Socket for splat requests.
my $REQUEST_HOST = 'crawl.akrasiac.org';
my $REQUEST_PORT = 21976;
my $RSOCK;
my $request_buf;

# Games requested for TV.
my $t_requested_games : shared = '';

my %opt;

# Fetch mode by default.
GetOptions(\%opt, 'local', 'filter=s');


############################  TV!  ####################################

my $SERVER      = '213.184.131.118'; # termcast server (probably don't change)
my $PORT        = 31337;             # termcast port (probably don't change)
my $NAME        = 'C_SPLAT';         # name to use on termcast
my $thres       = 3;                 # maximum sleep secs on a ttyrec frame
my @ALLGAMES;
my @TVGAMES;
my $SOCK;
my $WATCHERS = 0;
my $MOST_WATCHERS = 0;

my $PWFILE = 'tv.pwd';

sub read_password {
  chomp(my $text = do { local @ARGV = $PWFILE; <> });
  die "No password for termcast login?\n" unless $text;
  $text
}

my $PASS = read_password();   # pass to use on termcast

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
    tv_play($old);
  }
}

# Perform a last-minute check to see if the game is still there.
sub tv_game_exists {
  my $g = shift;
  query_one("SELECT COUNT(*) FROM ttyrec WHERE id = ?", $g->{id})
}


sub tv_show_playlist {
  my ($rplay, $prev) = @_;
  server_connect();
  print $SOCK clear_screen();
  if ($prev) {
    $prev = desc_game_brief($prev);
    print $SOCK "\e[1H\e[1;37mThat was:\e[0m\e[2H\e[1;33m$prev.\e[0m";
  }

  my $pos = 1 + ($prev ? 3 : 0);
  print $SOCK "\e[$pos;1H\e[1;37mComing up:\e[0m";
  $pos++;

  my $first = 1;
  my @display = @$rplay;
  if (@display > $PLAYLIST_SIZE) {
    @display = @display[0 .. ($PLAYLIST_SIZE - 1)];
  }
  for my $game (@display) {
    # Move to right position:
    print $SOCK "\e[$pos;1H";
    print $SOCK $first? "\e[1;34m" : "\e[0m";
    print $SOCK desc_game_brief($game);
    print $SOCK "\e[0m" if $first;
    undef $first;
    ++$pos;
  }

  sleep(5);
}

# Connect to splat request server.
sub connect_splat_request {
  #print "Connecting to splat request server.\n";
  $RSOCK = IO::Socket::INET->new(PeerAddr => $REQUEST_HOST,
                                 PeerPort => $REQUEST_PORT,
                                 Type => SOCK_STREAM,
                                 Timeout => 30);
}

sub find_requested_games {
  my $games = shift;

  my @games;

  my @requests = map(xlog_line($_), grep(/\S/, split(/\n/, $games)));
  warn "Got ", scalar(@requests), " new requests\n";

  for my $g (@requests) {
    delete $g->{start} if $g->{start} gt $g->{end};
    warn "Looking for games matching ", xlog_str($g), "\n";

    my $req = $g->{req};
    delete $g->{req};
    my @matches = grep(filter_matches($g, $_), @ALLGAMES);
    $g->{req} = $req;

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
  while (1) {
    connect_splat_request() unless $RSOCK;
    if ($RSOCK) {
      while (my $game = <$RSOCK>) {
        my ($g) = $game =~ /^\d+ (.*)/;
        chomp $g;
        {
          lock($t_requested_games);
          $t_requested_games .= "$g\n";
          warn "Request: $g\n";
        }
      }
    }
    undef $RSOCK;
    sleep 3;
  }
}

sub run_splat_request_thread {
  my $t = threads->new(\&check_splat_requests);
  $t->detach;
}

# Reconnect (or connect) to the termcast server and do the handshake.
# Returns () if an error occurred (such as not being able to connect)
# Otherwise returns the socket, which is ready to accept ttyrec frame data.
sub server_reconnect {
  my ($server, $port, $name, $pass) = @_;

  return if defined $SOCK;

  print "Attempting to connect...\n";

  $SOCK = IO::Socket::INET->new(PeerAddr => "$server:$port",
                                Proto    => 'tcp',
                                Type => SOCK_STREAM);
  die "Unable to connect: $!\n" unless defined $SOCK;
  return unless defined($SOCK);

  print "Trying to send handshake...\n";
  # Try to send the handshake
  print $SOCK "hello $name $pass\n";

  my $response = <$SOCK>;
  die "Bad response from server: $response ($!)\n"
    unless $response and $response =~ /^hello, $name\s*$/;

  print "Connected!\n";

  $SOCK
}

sub server_connect {
  if ($opt{local}) {
    $SOCK = \*STDOUT;
    $SOCK->autoflush;
    return $SOCK;
  }
  while (!defined($SOCK)) {
    server_reconnect($SERVER, $PORT, $NAME, $PASS);
    last if defined $SOCK;
    print "Unable to connect, trying again in 10s...\n";
    sleep 10;
  }
}

sub tv_play {
  my $g = shift;

  my ($ttr, $offset, $frame) = tty_frame_offset($g);

  print clear_screen();
  my $skipping = 1;
  for my $ttyrec (split / /, $g->{ttyrecs}) {
    if ($skipping) {
      next if $ttr ne $ttyrec;
      undef $skipping;
    }

    eval {
      tv_play_ttyrec($g, $ttyrec, $offset, $frame);
    };
    die "$@\n" if $@;

    undef $offset;
    undef $frame;
  }
}

sub check_watchers {
  my $sock_out = <$SOCK>;
  if (defined($sock_out)) {
    chomp $sock_out;
    if ($sock_out eq 'msg watcher connected') {
      ++$WATCHERS;
      print "New watcher! Up to $WATCHERS.";
      if ($WATCHERS > $MOST_WATCHERS) {
        $MOST_WATCHERS = $WATCHERS;
        print " That's a new record since this session has started!";
      }
      print "\n";
    }
    elsif ($sock_out eq 'msg watcher disconnected') {
      --$WATCHERS;
      print "Lost a watcher. Down to $WATCHERS.\n";
    }
    else { # Don't know how to handle it, so just echo
      print ">> $sock_out\n";
    }
  }
}

sub delta_seconds {
  my $delta = shift;
  Delta_Format($delta, 0, "%sh")
}

sub is_death_frame {
  my $frame = shift;
  $frame =~ /You die\.\.\./;
}

sub calc_perc {
  my ($num, $den) = @_;
  return "0.0" if $den == 0;
  sprintf "%.2f%%", ($num * 100 / $den)
}

sub tv_play_ttyrec {
  my ($g, $ttyrec, $offset, $frame) = @_;

  my $ttyfile = ttyrec_path($g, $ttyrec);
  server_connect();

  print $SOCK $frame if $frame;

  warn "Playing ttyrec for ", desc_game($g), " from $ttyfile\n";

  my $t = Term::TtyRec::Plus->new(infile => $ttyfile,
                                  time_threshold => 3);
  seek($t->filehandle(), $offset, SEEK_SET) if $offset;
  while (my $fref = $t->next_frame()) {
    select undef, undef, undef, $fref->{diff};
    print $SOCK tv_frame_strip($fref->{data});
    select undef, undef, undef, 1 if is_death_frame($fref->{data});
  }
  close($t->filehandle());
}

open_db();
run_tv();
