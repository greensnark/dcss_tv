#! /usr/bin/perl

use strict;
use warnings;

use Getopt::Long;
use CSplat::Config qw/game_server/;
use CSplat::DB qw/%PLAYED_GAMES load_played_games open_db
                  fetch_all_games record_played_game
                  clear_played_games query_one/;
use CSplat::Xlog qw/desc_game desc_game_brief xlog_line/;
use CSplat::Ttyrec qw/$TTYRMINSZ $TTYRMAXSZ $TTYRDEFSZ ttyrec_path
                      ttyrec_file_time tty_time/;
use CSplat::Select qw/filter_matches/;
use Term::VT102;
use Term::TtyRec::Plus;
use IO::Socket::INET;
use Date::Manip;

use threads;
use threads::shared;

# An appropriately Crawlish number.
my $PLAYLIST_SIZE = 9;

# A standard VT102 to grab frames from.
my $TERM_X = 80;
my $TERM_Y = 24;
my $TERM = Term::VT102->new(cols => $TERM_X, rows => $TERM_Y);

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

sub build_playlist {
  my $pref = shift;

  # Check for new ttyrecs in the DB.
  scan_ttyrec_list();

  my @requested_games = get_requested_games();

  if (@requested_games) {
    # Note that this game is a request.
    $_->{req} = 'y' for @requested_games;

    # Any requested games go to the top of the playlist.
    unshift @$pref, @requested_games;

    # And then we eliminate duplicates.
    my %ids;
    @$pref = grep(!$ids{$_->{id}}++, @$pref);
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

sub clear_screen {
  "\e[2J"
}

sub tv_cache_reset {
  $TERM->process(clear_screen());
  # Go to first row and reset attributes.
  $TERM->process("\e[1H\e[0m");
}

sub tv_cache_frame {
  $TERM->process($_[0]);
}

sub tv_chattr_s {
  my $attr = shift;
  my ($fg, $bg, $bo, $fa, $st, $ul, $bl, $rv) = $TERM->attr_unpack($attr);

  my @attr;
  push @attr, 1 if $bo || $st;
  push @attr, 2 if $fa;
  push @attr, 4 if $ul;
  push @attr, 5 if $bl;
  push @attr, 7 if $rv;

  my $attrs = @attr? join(';', @attr) . ';' : '';
  "\e[0;${attrs}3$fg;4${bg}m"
}

# Return the current term contents as a single frame that can be written
# to a terminal.
sub tv_frame {
  my $frame = "\e[2J\e[0m";
  my $lastattr = '';
  for my $row (1 .. $TERM_Y) {
    my $text = $TERM->row_plaintext($row);
    my $tattr = $TERM->row_attr($row);
    next unless $text =~ /[^ ]/;
    $frame .= "\e[${row}H";
    for (my $i = 0; $i < $TERM_X; ++$i) {
      my $attr = substr($tattr, $i * 2, 2);
      $frame .= tv_chattr_s($attr) if $attr ne $lastattr;
      $frame .= substr($text, $i, 1);
      $lastattr = $attr;
    }
  }

  my ($x, $y, $attr) = $TERM->status();
  $frame .= "\e[$y;${x}H";
  $frame .= tv_chattr_s($attr) unless $attr eq $lastattr;

  $frame
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
  for my $game (@$rplay) {
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
  for my $gameline (split /\n/, $games) {
    next unless $gameline;
    my $g = xlog_line($gameline);
    warn "Looking for games matching $gameline\n";
    push(@games, grep(filter_matches($g, $_), @ALLGAMES));
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
          warn "Request: $g\n";
          $t_requested_games .= "$g\n";
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

  my $sz = $g->{sz};
  my $skipsize = 0;
  if ($sz > $TTYRDEFSZ) {
    $skipsize = $sz - $TTYRDEFSZ;
  }

  for my $ttyrec (split / /, $g->{ttyrecs}) {
    my $thisz = -s(ttyrec_path($g, $ttyrec));
    if ($skipsize >= $thisz) {
      $skipsize -= $thisz;
      $sz -= $thisz;
      next;
    }

    eval {
      tv_play_ttyrec($g, $ttyrec, $sz, $skipsize);
    };
    $skipsize = 0;
    $sz -= $thisz;
    warn "$@\n" if $@;
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

sub tv_frame_strip {
  my $rdat = shift;

  # Strip IBM graphics, kthx.
  $rdat =~ tr/\xB1\xB0\xF9\xFA\xFE\xDC\xEF\xF4\xF7/#*.,+_\\}{/;

  # Strip unicode. Rather pricey :(
  $rdat =~ s/\xe2\x96\x92/#/g;
  $rdat =~ s/\xe2\x96\x91/*/g;
  $rdat =~ s/\xc2\xb7/./g;
  $rdat =~ s/\xe2\x97\xa6/,/g;
  $rdat =~ s/\xe2\x97\xbc/+/g;
  $rdat =~ s/\xe2\x88\xa9/\\/g;
  $rdat =~ s/\xe2\x8c\xa0/}/g;
  $rdat =~ s/\xe2\x89\x88/{/g;

  $rdat
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
  my ($g, $ttyrec, $total_size, $skip, $buildup_from) = @_;

  my $ttyfile = ttyrec_path($g, $ttyrec);
  server_connect();

  my $size = -s $ttyfile;
  my $skipsize = 0;

  if ($skip) {
    $skipsize = $skip if $skip > 0 && $skip < $size;
    my $perc = calc_perc($skipsize, $total_size);
    warn "\nNeed to skip $skipsize of $total_size ($perc) bytes\n" if $skipsize;
  }

  warn "Playing ttyrec for ", desc_game($g), " from $ttyfile\n";

  my $t = Term::TtyRec::Plus->new(infile => $ttyfile,
                                  time_threshold => 3);
  my $ttyrec_time = ttyrec_file_time($ttyfile);
  my $end_time = tty_time($g, 'end');

  my $delta = delta_seconds(DateCalc($ttyrec_time, $end_time));
  my $fc = 0;
  my $lastclear = 0;
  my $lastgoodclear = 0;

  tv_cache_reset();

  warn "Building up from $buildup_from\n" if $buildup_from;
  my $buildupbegun;
  while (my $fref = $t->next_frame()) {
    if ($skipsize) {
      my $pos = tell($t->filehandle());
      my $hasclear = index($fref->{data}, "\033[2J") > -1;
      $lastclear = $pos if $hasclear;
      $lastgoodclear = $pos if $hasclear && $total_size - $pos >= $TTYRMINSZ;

      if ($buildup_from && $pos >= $buildup_from) {
        tv_cache_frame(tv_frame_strip($fref->{data}));
      }

      next if $pos < $skipsize;

      if ($hasclear) {
        my $size_left = $total_size - $pos;
        if ($size_left < $TTYRMINSZ && $lastgoodclear < $pos
            && $total_size - $lastgoodclear >= $TTYRMINSZ
            && !$buildup_from)
        {
          warn "Not enough of ttyrec left at $pos, ",
                "cache-rewinding from $lastgoodclear\n";
          close($t->filehandle());
          return tv_play_ttyrec($g, $ttyrec, $total_size,
                                $skipsize, $lastgoodclear);
        }

        undef $skipsize;
        my $perc = calc_perc($pos, $total_size);
        warn "Done skip at $pos of $total_size ($perc), ",
          "starting normal playback\n";
        warn "Size left: $size_left, min: $TTYRMINSZ\n";
      } else {
        # If we've been building up a frame in our VT102, spit that out now.
        if ($buildup_from && $buildup_from < $pos) {
          warn "Done skip, writing buffer!\n";
          print $SOCK tv_frame();
          undef $skipsize;
        }
        next;
      }
    }
    select undef, undef, undef, $fref->{diff};
    print $SOCK tv_frame_strip($fref->{data});
    select undef, undef, undef, 1 if is_death_frame($fref->{data});
  }

  close($t->filehandle());

  if ($skipsize) {
    tv_play_ttyrec($g, $ttyrec, $lastclear);
  }
}

open_db();
run_tv();
