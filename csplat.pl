#! /usr/bin/perl

use strict;
use warnings;
use IO::Handle;
use IO::Socket::INET;
use Term::TtyRec::Plus;
use File::Path;
use Date::Manip;
use DBI;
use Memoize;
use LWP::Simple;
use Fcntl qw/SEEK_SET/;

memoize('fetch_ttyrec_urls_from_server');

# Overall strategy:
# * Fetch logfiles.
# * Scan logfiles to pick games. Keep track of logfile offsets.
# * For selected games, check server to see if we have ttyrecs.
# * Grab ttyrecs and drop them in ttyrec directory.
# * Spawn tv once we have three games' worth of ttyrec.
# * As we load more games, write them into ttyrec dir, update
#   index card for ttyrecs (with game info).
# * Strip unicode, ibm as we play.
#
# Todo:
# * Set a combined size limit for ttyrecs per game (2M?)
# * Download ttyrecs and check each one to make sure it's 80x24.
# * Stream for fun and profit!

my $DATA_DIR = 'data';
my $TTYREC_DIR = "$DATA_DIR/ttyrecs";

my @LOG_URLS = ('http://crawl.akrasiac.org/allgames.txt',
                'http://crawl.akrasiac.org/logfile04');

my $TRAIL_DB = 'data/splat.db';
my @LOG_FILES = map { m{.*/(.*)} } @LOG_URLS;

my @IPLACES = qw/Tomb Dis Tar Geh Coc Vault Crypt Zot Pan/;

my $CAO_UTC_EPOCH = ParseDate("2008-08-07 03:30 UTC");
my $CAO_BEFORE = DateCalc($CAO_UTC_EPOCH, "-2 days");
my $CAO_AFTER = DateCalc($CAO_UTC_EPOCH, "+2 days");

my %SERVMAP =
  ('crawl.akrasiac.org' => { tz => 'EST',
                             ttypath => 'http://crawl.akrasiac.org/rawdata' });

# Smallest cumulative length of ttyrec that's acceptable.
my $TTYRMINSZ = 250 * 1024;

# Largest cumulative length of ttyrec.
my $TTYRMAXSZ = 10 * 1024 * 1024;

# Default ttyrec length.
my $TTYRDEFSZ = 600 * 1024;

my $MINPLAYLIST = 15;

# Approximate compression of a ttyrec.bzip2
my $BZ2X = 11;

my $NOTTYP = 1;

my $DBH;

sub main {
  check_dirs();
  open_db();
  fetch_logs(@LOG_URLS);
  while (1) {
    trawl_games();
    sleep 600;
  }
}

sub check_dirs {
  mkpath( [ $DATA_DIR, $TTYREC_DIR ] );
}

sub open_db {
  my $size = -s $TRAIL_DB;
  $DBH = DBI->connect("dbi:SQLite:$TRAIL_DB");
  create_tables($DBH) unless defined($size) && $size > 0;
}

sub close_db {
  if ($DBH) {
    $DBH->disconnect();
    undef $DBH;
  }
}

sub reopen_db {
  close_db();
  open_db();
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
                   );
  for my $line (@ddl_lines) {
    $dbh->do($line) or die "Can't create table schema!";
  }
}

sub url_file {
  my $url = shift;
  my ($file) = $url =~ m{.*/(.*)};
  $file
}

sub log_path {
  my $url = shift;
  $DATA_DIR . "/" . url_file($url)
}

sub ttyrec_path {
  my $url = shift;
  $TTYREC_DIR . "/" . url_file($url)
}

sub fetch_url {
  my ($url, $file) = @_;
  $file ||= url_file($url);
  my $command = "wget -q -c -O $file $url";
  my $status = system $command;
  die "Error fetching $url: $?\n" if $status;
}

sub fetch_logs {
  my @logs = @_;

  for my $log (@logs) {
    fetch_url($log, log_path($log));
  }
}

sub check_exec {
  my ($query, $sub) = @_;
  while (1) {
    my $res = $sub->();
    return $res if $res;
    my $reason = $!;
    # If SQLite wants us to retry, sleep one second and take another stab at it.
    die "Failed to execute $query: $!\n"
      unless $reason =~ /temporarily unavail/i;
    sleep 1;
  }
}

sub exec_query {
  my ($query, @pars) = @_;
  my $st = $DBH->prepare($query) or die "Can't prepare $query: $!\n";
  check_exec( $query, sub { $st->execute(@pars) } );
  $st
}

sub query_one {
  my ($query, @pars) = @_;
  if (@pars) {
    my $st = exec_query($query, @pars);
    my $rrow = $st->fetchrow_arrayref();
    $rrow->[0]
  }
  else {
    my $rrow = check_exec($query, sub { $DBH->selectrow_arrayref($query) });
    $rrow->[0];
  }
}

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

sub xlog_line {
  my $text = shift;
  $text =~ s/::/\n/g;
  my @fields = map { (my $x = $_) =~ tr/\n/:/; $x } split /:/, $text;
  my %hash = map /^(\w+)=(.*)/, @fields;
  \%hash
}

sub xlog_str {
  my $xlog = shift;
  my %hash = %$xlog;
  delete $hash{src};
  delete $hash{offset};
  delete $hash{ttyrecs};
  delete $hash{ttyrecurls};
  join(":", map { "$_=$hash{$_}" } keys(%hash))
}

sub read_log {
  my ($fh, $log) = @_;
  my $pos = tell $fh;
  my $line = <$fh>;
  return unless $line =~ /\n$/;
  chomp $line;
  my $fields = xlog_line($line);
  $fields->{offset} = $pos;
  $fields->{src} = $log;
  $fields
}

sub record_game {
  my $game = shift;
  exec_query("INSERT INTO ttyrec (logrecord, ttyrecs)
              VALUES (?, ?)",
             xlog_str($game), $game->{ttyrecs});
}

sub record_log_place {
  my ($log, $game) = @_;
  exec_query("INSERT INTO logplace (logfile, offset)
              VALUES (?, ?)",
             $log, $game->{offset});
}

sub start_ttyplay {
  print "Forking tty player.";
  undef $NOTTYP;

  my $pid = fork;
  die "Couldn't fork tv!\n" unless defined $pid;

  # Parent returns here.
  return if $pid != 0;

  # The child runs tv forever.
  run_tv();
}

sub place_prefix {
  my $place = shift;
  return $place if index($place, ':') == -1;
  $place =~ s/:.*//;
  $place
}

sub place_depth {
  my $place = shift;
  my ($depth) = $place =~ /:(\d+)/;
  $depth || 1
}

sub is_interesting_place {
  # We're interested in Zot, Hells, Vaults, Tomb.
  my ($place, $xl) = @_;
  my $prefix = place_prefix($place);
  my $depth = place_depth($place);
  return 1 if $prefix eq 'Elf' && $depth >= 6;
  return 1 if $prefix eq 'Slime' && $depth >= 5;
  return if $prefix eq 'Vault' && $xl < 24;
  ($place =~ "Abyss" && $xl > 20)
    || grep($prefix eq $_, @IPLACES)
}

sub interesting_game {
  my $g = shift;

  my $ktyp = $g->{ktyp};
  return if grep($ktyp eq $_, qw/quitting leaving winning/);

  my $xl = $g->{xl};
  my $place = $g->{place};

  my $good = $xl >= 25 || (is_interesting_place($place, $xl) && $xl > 10);
  print desc_game($g), " looks interesting!\n" if $good;
  $good
}

sub count_existing_games {
  query_one("SELECT COUNT(*) FROM ttyrec")
}

sub game_server {
  my $g = shift;
  my $src = $g->{src};
  my ($server) = $src =~ m{^http://(.*?)/};
  $server
}

sub server_field {
  my ($g, $field) = @_;
  my $server = game_server($g);

  my $sfield = $SERVMAP{$server} or die "Unknown server: $server\n";
  $sfield->{$field}
}

sub tty_tz_time {
  my ($g, $time) = @_;
  my $dst = $time =~ /D$/;
  $time =~ s/[DS]$//;

  my $tz = server_field($g, 'tz');
  $tz =~ s/ST$/DT/ if $dst;

  ParseDate("$time $tz")
}

sub fix_crawl_time {
  my $time = shift;
  $time =~ s/^(\d{4})(\d{2})/ sprintf "%04d%02d", $1, $2 + 1 /e;
  $time
}

sub tty_time {
  my ($g, $which) = @_;
  my $time = fix_crawl_time($g->{$which});
  (my $stripped = $time) =~ s/[DS]$//;

  # First parse it as UTC.
  my $parsed = ParseDate("$stripped UTC");

  # If it was before the UTC epoch, parse it as the appropriate local time.
  $parsed = tty_tz_time($g, $time) if $parsed lt $CAO_UTC_EPOCH;
  $parsed
}

sub utc_time {
  my $time = shift;
  Date_ConvTZ($time, "", "UTC")
}

sub ttyrec_between {
  my ($tty, $start, $end) = @_;
  my $url = $tty->{u};
  my ($date) = $url =~ /(\d{4}-\d{2}-\d{2}\.\d{2}:\d{2}:\d{2})/;
  die "ttyrec url ($url) contains no date?\n" unless $date;
  my $pdate = ParseDate("$date UTC");
  $pdate ge $start && $pdate le $end
}

sub desc_game {
  my $g = shift;
  my $god = $g->{god} ? ", worshipper of $g->{god}" : "";
  my $dmsg = $g->{vmsg} || $g->{tmsg};
  my $place = $g->{place};
  my $ktyp = $g->{ktyp};

  my $prep = grep($_ eq $place, qw/Temple Blade Hell/)? "in" : "on";
  $prep = "in" if $g->{ltyp} ne 'D';
  $place = "the $place" if grep($_ eq $place, qw/Temple Abyss/);
  $place = "a Labyrinth" if $place eq 'Lab';
  $place = "a Bazaar" if $place eq 'Bzr';
  $place = "Pandemonium" if $place eq 'Pan';
  $place = " $prep $place";
  my $when = " on " . fix_crawl_time($g->{end});

  "$g->{name} the $g->{title} ($g->{xl} $g->{char})$god, $dmsg$place$when, " .
    "after $g->{turn} turns"
}

sub desc_game_brief {
  my $g = shift;
  my $desc = desc_game($g);
  $desc =~ s/,.*//;
  $desc
}

sub download_ttyrecs {
  my $g = shift;

  my $sz = 0;

  my @ttyrs = reverse @{$g->{ttyrecurls}};

  my @tofetch;
  for my $tty (@ttyrs) {
    last if $sz >= $TTYRDEFSZ;
    my $ttysz = $tty->{sz};
    # Fudge size if the ttyrec is compressed.
    $ttysz *= $BZ2X if $tty->{u} =~ /bz2$/;
    $sz += $ttysz;

    push @tofetch, $tty;
  }

  if ($sz > $TTYRMAXSZ || $sz < $TTYRMINSZ) {
    print "ttyrec total size for " . desc_game($g) .
      " = $sz is out of bounds.\n";
    return;
  }

  @tofetch = reverse(@tofetch);
  print "Downloading ", scalar(@tofetch), " ttyrecs for ", desc_game($g), "\n";
  for my $url (@tofetch) {
    my $path = ttyrec_path($url->{u});
    fetch_url($url->{u}, ttyrec_path($url->{u}));
  }

  $g->{sz} = $sz;
  $g->{ttyrecs} = join(" ", map($_->{u}, @tofetch));
  $g->{ttyrecurls} = \@tofetch;

  1
}

sub fetch_ttyrecs {
  my $g = shift;
  my $start = tty_time($g, 'start');
  my $end = tty_time($g, 'end');

  # Check for the dgl start time bug.
  return if $start ge $end;

  # If the game was in the hazy date range when Crawl was between
  # UTC and local time, skip.
  return if ($end ge $CAO_BEFORE && $end le $CAO_AFTER) ||
    ($start ge $CAO_BEFORE && $start le $CAO_AFTER);

  my @ttyrecs = find_ttyrecs($g) or return;
  @ttyrecs = grep(ttyrec_between($_, $start, $end), @ttyrecs);
  return unless @ttyrecs;

  $g->{ttyrecs} = join(" ", map($_->{u}, @ttyrecs));
  $g->{ttyrecurls} = \@ttyrecs;
  download_ttyrecs($g)
}

sub clean_ttyrec_url {
  my ($baseurl, $url) = @_;
  $url->{u} =~ s{^./}{};
  $baseurl = "$baseurl/" unless $baseurl =~ m{/$};
  $url->{u} = $baseurl . $url->{u};
  $url
}

sub human_readable_size {
  my $size = shift;
  my ($suffix) = $size =~ /([KMG])$/i;
  $size =~ s/[KMG]$//i;
  if ($suffix) {
    $suffix = lc($suffix);
    $size *= 1024 if $suffix eq 'k';
    $size *= 1024 * 1024 if $suffix eq 'm';
    $size *= 1024 * 1024 * 1024 if $suffix eq 'g';
  }
  $size
}

sub fetch_ttyrec_urls_from_server {
  my ($name, $userpath) = @_;
  print "Fetching ttyrec listing for $name\n";
  my $listing = get($userpath) or return ();
  my @urlsizes = $listing =~ /a\s+href\s*=\s*["'](.*?)["'].*?([\d.]+[kM])\b/gi;
  my @urls;
  for (my $i = 0; $i < @urlsizes; $i += 2) {
    my $url = $urlsizes[$i];
    my $size = human_readable_size($urlsizes[$i + 1]);
    push @urls, { u => $url, sz => $size };
  }
  my @ttyrecs = map(clean_ttyrec_url($userpath, $_),
                    grep($_->{u} =~ /\.ttyrec/, @urls));
  @ttyrecs
}

sub find_ttyrecs {
  my $g = shift;
  my $servpath = server_field($g, 'ttypath');
  my $userpath = "$servpath/$g->{name}";

  my @urls = fetch_ttyrec_urls_from_server($g->{name}, $userpath);
  @urls
}

sub trawl_games {
  my $lines = 0;
  my $games = 0;
  my $existing_games = count_existing_games();
  start_ttyplay() if $existing_games >= $MINPLAYLIST;

  for my $log (@LOG_URLS) {
    # Go to last point that we processed.
    my $fh = seek_log($log);
    $DBH->begin_work;
    while (my $game = read_log($fh, $log)) {
      if (interesting_game($game) && fetch_ttyrecs($game)) {
        $games++;
        record_game($game);

        if ($NOTTYP && $games + $existing_games >= $MINPLAYLIST) {
          start_ttyplay();
        }
      }
      record_log_place($log, $game);

      if (!(++$lines % 100)) {
        my $total = $games + $existing_games;
        print "Scanned $lines lines, found $total interesting games\n";
        $DBH->commit;
        $DBH->begin_work;
      }
    }
    $DBH->commit;
  }
}

############################  TV!  ####################################

my $SERVER      = '213.184.131.118'; # termcast server (probably don't change)
my $PORT        = 31337;             # termcast port (probably don't change)
my $NAME        = 'CSPLAT';          # name to use on termcast
my $thres       = 3;                 # maximum sleep secs on a ttyrec frame
my %PLAYED_GAMES;                    # hash tracking db ids of ttyrecs played
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
  my $query = "SELECT id, logrecord, ttyrecs FROM ttyrec";
  my $rows =
    check_exec(
      $query,
      sub { $DBH->selectall_arrayref($query) } );

  @TVGAMES = ();
  for my $row (@$rows) {
    my $id = $row->[0];
    my $g = xlog_line($row->[1]);
    $g->{ttyrecs} = $row->[2];
    $g->{id} = $id;
    push @TVGAMES, $g;
  }
  die "No games to play!\n" unless @TVGAMES;
  @TVGAMES = grep(!$PLAYED_GAMES{$_->{id}}, @TVGAMES);
}

sub pick_random_unplayed {
  unless (@TVGAMES) {
    %PLAYED_GAMES = ();
    scan_ttyrec_list();
  }
  my $game = $TVGAMES[int(rand(@TVGAMES))];
  $PLAYED_GAMES{$game->{id}} = 1;
  $game
}

sub run_tv {
  reopen_db();
  my $old;
  while (1) {
    # Check for new ttyrecs in the DB.
    scan_ttyrec_list();
    my $g = pick_random_unplayed();
    say_now_playing($g, $old);
    $old = $g;
    tv_play($g);
  }
}

sub say_now_playing {
  my ($this, $prev) = @_;
  $this = desc_game_brief($this);
  server_connect();
  if ($prev) {
    $prev = desc_game_brief($prev);
    print $SOCK "\e[2J\e[H";
    print $SOCK "That was \e[1;33m$prev.\e[0m\e[2;0H" if $prev;
  }
  print $SOCK "Now playing \e[1;33m$this\e[0m.";
  sleep 5;
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
#   if (1) {
#     $SOCK = \*STDOUT;
#     $SOCK->autoflush;
#     return $SOCK;
#   }
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
  for my $ttyrec (split / /, $g->{ttyrecs}) {
    tv_play_ttyrec($g, $ttyrec, $sz && $sz > $TTYRDEFSZ);
    undef $sz;
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

sub tv_frame_filter {
  my ($rdat, $rts, $rpts) = @_;
  # Strip IBM graphics, kthx.
  $$rdat =~ tr/\xB1\xB0\xF9\xFA\xFE\xDC\xEF\xF4\xF7/#*.,+_\\}{/;
}

sub tv_play_ttyrec {
  my ($g, $ttyrec, $skip) = @_;
  my $ttyfile = ttyrec_path($ttyrec);
  server_connect();
  #check_watchers();

  my $size = -s $ttyfile;
  my $skipsize = 0;

  if ($skip) {
    $size *= $BZ2X if $ttyfile =~ /.bz2$/;
    if ($size > $TTYRDEFSZ * 1.5) {
      $skipsize = $size - int($TTYRDEFSZ * 1.5);
    }
  }

  print "Playing ttyrec for ", desc_game($g), " from $ttyfile\n";

  my $t = Term::TtyRec::Plus->new(infile => $ttyfile,
                                  time_threshold => 3,
                                  frame_filter => \&tv_frame_filter);
  while (my $fref = $t->next_frame()) {
    if ($skipsize) {
      next if tell($t->filehandle()) < $skipsize;
      if (index($fref->{data}, "\033[2J") > -1) {
        undef $skipsize;
        print "Done skip, starting normal playback\n";
      } else {
        next;
      }
    }
    select undef, undef, undef, $fref->{diff};
    print $SOCK $fref->{data};
  }
  close($t->filehandle());
}

#######################################################################

if (grep /-tv/, @ARGV) {
  run_tv();
}
else {
  main();
}
