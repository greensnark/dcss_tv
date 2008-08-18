#! /usr/bin/perl

# C-SPLAT by greensnark.
# Based on TermCastTv 1.2 by Eidolos.

use strict;
use warnings;
use IO::Handle;
use IO::Socket::INET;
use Term::TtyRec::Plus;
use File::Path;
use Date::Manip;
use DBI;
use LWP::Simple;
use Getopt::Long;
use Carp;
use Fcntl qw/SEEK_SET/;

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

my $DATA_DIR = 'data';
my $TTYREC_DIR = "$DATA_DIR/ttyrecs";

my $FETCH_ONLY = 0;

my @LOG_URLS = ('http://crawl.akrasiac.org/allgames.txt',
                'http://crawl.akrasiac.org/logfile04',
                'http://crawl.develz.org/allgames-old.txt',
                'http://crawl.develz.org/allgames-rel.txt',
                'http://crawl.develz.org/allgames-svn.txt');

my $TRAIL_DB = 'data/splat.db';
my @LOG_FILES = map { m{.*/(.*)} } @LOG_URLS;

my @IPLACES = qw/Tomb Dis Tar Geh Coc Vault Crypt Zot Pan/;

my $UTC_EPOCH = ParseDate("2008-07-30 10:30 UTC");
my $UTC_BEFORE = DateCalc($UTC_EPOCH, "-1 days");
my $UTC_AFTER = DateCalc($UTC_EPOCH, "+2 days");

my $BLACKLIST = 'blacklist.txt';

# Games blacklisted.
my @BLACKLISTED;

my %SERVMAP =
  ('crawl.akrasiac.org' => { tz => 'EST',
                             dsttz => 'EDT',
                             ttypath => 'http://crawl.akrasiac.org/rawdata' },
   'crawl.develz.org' => { tz => 'CET', dsttz => 'CEST',
                           ttypath => 'http://crawl.develz.org/ttyrecs' });

# Smallest cumulative length of ttyrec that's acceptable.
my $TTYRMINSZ = 60 * 1024;

# Largest cumulative length of ttyrec. The longer it gets, the harder we
# have to work to seek to the fun parts.
my $TTYRMAXSZ = 70 * 1024 * 1024;

# Default ttyrec length.
my $TTYRDEFSZ = 130 * 1024;

# Approximate compression of ttyrecs
my $BZ2X = 11;
my $GZX = 6.6;

my %FETCHED_GAMES;
my %CACHED_TTYREC_URLS;

my %opt;

# Fetch mode by default.
GetOptions(\%opt, 'tv', 'rescan', 'local', 'migrate',
           'sanity-check', 'sanity-fix');

my $DBH;

sub fetch {
  check_dirs();
  update_fetched_games();
  rescan_games() if $opt{rescan};
  while (1) {
    fetch_logs(@LOG_URLS);
    trawl_games();
    print "Sleeping between log scans...\n";
    sleep 600;
    %CACHED_TTYREC_URLS = ();
  }
}

sub load_blacklist {
  open my $inf, '<', $BLACKLIST or return;
  while (<$inf>) {
    next unless /\S/ and !/^\s*#/;
    my $game = xlog_line($_);
    push @BLACKLISTED, $game;
  }
  close $inf;
}

sub is_blacklisted {
  my $g = shift;
BLACK_MAIN:
  for my $b (@BLACKLISTED) {
    for my $key (keys %$b) {
      next BLACK_MAIN if $$b{$key} ne $$g{$key};
    }
    return 1;
  }
  undef
}

# Check if all the ttyrecs we have are death ttyrecs. If sanity-fix is set,
# will also delete games that have no death ttyrecs.
sub sanity_check {
  my @games = fetch_all_games();
  print "Running sanity-check";
  print ", will fix errors." if $opt{'sanity-fix'};
  print "\n";

  for my $g (@games) {
    my @ttyrecs = split / /, $g->{ttyrecs};
    if (!is_death_ttyrec($g, $ttyrecs[-1])) {
      warn "Game has no death ttyrec: ", desc_game($g), "\n";
      if ($opt{'sanity-fix'}) {
        delete_game($g);
      }
      next;
    }

    if (ttyrecs_out_of_time_bounds($g)) {
      warn "Game has out-of-range ttyrecs: ", desc_game($g), "\n";
      if ($opt{'sanity-fix'}) {
        delete_game($g);
      }
      next;
    }
  }
}

sub ttyrecs_out_of_time_bounds {
  my $g = shift;
  my $start = tty_time($g, 'start');
  my $end = tty_time($g, 'end');
  for my $tty (split / /, $g->{ttyrecs}) {
    if (!ttyrec_between($tty, $start, $end)) {
      warn "ttyrec is not between $start and $end: ", $tty, "\n";
      return 1;
    }
  }
  undef
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

sub game_unique_key {
  my $g = shift;
  "$g->{name}|$g->{end}|$g->{src}"
}

sub record_fetched_game {
  my $g = shift;
  $FETCHED_GAMES{game_unique_key($g)} = 1;
}

sub update_fetched_games {
  my @games = fetch_all_games();
  for my $g (@games) {
    record_fetched_game($g);
  }
}

sub game_was_fetched {
  my $g = shift;
  $FETCHED_GAMES{game_unique_key($g)}
}

# Goes through all the games we've flagged in the DB, deleting those
# that don't match interesting_game.
sub rescan_games {
  my @games = fetch_all_games();
  $DBH->begin_work;
  for my $g (@games) {
    if (!interesting_game($g)) {
      delete_game($g);
    }
  }

  my $purge = "DELETE FROM logplace";
  # And reset our log positions so we rescan the entire logfile.
  check_exec($purge, sub { $DBH->do("DELETE FROM logplace") });

  $DBH->commit;
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
  my ($g, $url) = @_;
  my $server = game_server($g);
  my $dir = "$TTYREC_DIR/$server/$g->{name}";
  mkpath( [ $dir ] ) unless -d $dir;
  $dir . "/" . url_file($url)
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

sub exec_do {
  my $query = shift;
  check_exec($query, sub { $DBH->do($query) })
}

sub exec_all {
  my $query = shift;
  check_exec($query,
             sub { $DBH->selectall_arrayref($query) })
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
  chomp(my $text = shift);
  $text =~ s/::/\n/g;
  my @fields = map { (my $x = $_) =~ tr/\n/:/; $x } split /:/, $text;
  my %hash = map /^(\w+)=(.*)/, @fields;
  \%hash
}

sub escape_xlogfield {
  my $field = shift;
  $field =~ s/:/::/;
  $field
}

sub xlog_str {
  my $xlog = shift;
  my %hash = %$xlog;
  delete $hash{offset};
  delete $hash{ttyrecs};
  delete $hash{ttyrecurls};
  join(":", map { "$_=@{[ escape_xlogfield($hash{$_}) ]}" } keys(%hash))
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

sub record_game {
  my $game = shift;
  record_fetched_game($game);
  exec_query("INSERT INTO ttyrec (logrecord, ttyrecs)
              VALUES (?, ?)",
             xlog_str($game), $game->{ttyrecs});
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
  return 1 if $place eq 'Elf:7' && $xl >= 17;
  return 1 if $place =~ /Vault:[78]/ && $xl >= 16;
  return 1 if $place eq 'Blade' && $xl >= 18;
  return 1 if $place eq 'Slime:6';
  return if $prefix eq 'Vault' && $xl < 24;
  ($place =~ "Abyss" && $xl > 24)
    || grep($prefix eq $_, @IPLACES)
    # Hive drowning is fun!
    || $place eq 'Hive:4'
}

my @COOL_UNIQUES = qw/Boris Frederick Geryon Xtahua Murray
                      Norris Margery Rupert/;

my %COOL_UNIQUES = map(($_ => 1), @COOL_UNIQUES);

sub interesting_game {
  my $g = shift;

  # Just in case, check for wizmode games.
  return if $g->{wiz};

  my $ktyp = $g->{ktyp};
  return if grep($ktyp eq $_, qw/quitting leaving winning/);

  # No matter how high level, ignore Temple deaths.
  return if $g->{place} eq 'Temple';

  my $start = tty_time($g, 'start');
  my $end = tty_time($g, 'end');

  # Check for the dgl start time bug.
  return if $start ge $end;

  # If the game was in the hazy date range when Crawl was between
  # UTC and local time, skip.
  return if ($end ge $UTC_BEFORE && $end le $UTC_AFTER);

  if (is_blacklisted($g)) {
    warn "Game is blacklisted: ", desc_game($g), "\n";
    return;
  }

  my $xl = $g->{xl};
  my $place = $g->{place};
  my $killer = $g->{killer} || '';

  my $good =
    $xl >= 25 || (is_interesting_place($place, $xl) && $xl > 10)
      # High-level player ghost splats.
      || ($xl >= 15 && $killer =~ /'s? ghost/)
      || ($xl >= 15 && $COOL_UNIQUES{$killer});

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
  confess "No server in $src\n" unless $server;
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

  my $tz = server_field($g, $dst? 'dsttz' : 'tz');
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
  $parsed = tty_tz_time($g, $time) if $parsed lt $UTC_EPOCH;
  $parsed
}

sub ttyrec_file_time {
  my $url = shift;
  my ($date) = $url =~ /(\d{4}-\d{2}-\d{2}\.\d{2}:\d{2}:\d{2})/;
  die "ttyrec url ($url) contains no date?\n" unless $date;
  ParseDate("$date UTC")
}

sub ttyrec_between {
  my ($tty, $start, $end) = @_;
  my $pdate = ttyrec_file_time( $tty );
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

  "$g->{name} the $g->{title} (L$g->{xl} $g->{char})$god, $dmsg$place$when, " .
    "after $g->{turn} turns"
}

sub desc_game_brief {
  desc_game(@_)
}

sub fudge_size {
  my ($sz, $url) = @_;
  # Fudge size if the ttyrec is compressed.
  $sz *= $BZ2X if $url =~ /\.bz2$/;
  $sz *= $GZX if $url =~ /\.gz$/;
  $sz
}

sub uncompress_ttyrec {
  my ($g, $url) = @_;
  if ($url->{u} =~ /.bz2$/) {
    system "bunzip2 -f " . ttyrec_path($g, $url->{u})
      and die "Couldn't bunzip $url->{u}\n";
    $url->{u} =~ s/\.bz2$//;
  }
  if ($url->{u} =~ /.gz$/) {
    system "gunzip -f " . ttyrec_path($g, $url->{u})
      and die "Couldn't gunzip $url->{u}\n";
    $url->{u} =~ s/\.gz$//;
  }
}

sub is_death_ttyrec {
  my ($g, $u) = @_;
  my $file = ttyrec_path($g, $u);
  # Set line delimiter to escape for sane grepping through ttyrecs.
  local $/ = "\033";
  open my $inf, '<', $file
    or do {
      warn "Couldn't open $file: $!\n";
      return;
    };
  while (<$inf>) {
    return 1 if /You die\.\.\./;
  }
  undef
}

sub download_ttyrecs {
  my $g = shift;

  my $sz = 0;

  my @ttyrs = reverse @{$g->{ttyrecurls}};

  my @tofetch;
  for my $tty (@ttyrs) {
    last if $sz >= $TTYRDEFSZ;

    my $ttysz = $tty->{sz};
    $ttysz = fudge_size($ttysz, $tty->{u});
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
  $sz = 0;
  for my $url (@tofetch) {
    my $path = ttyrec_path($g, $url->{u});
    fetch_url($url->{u}, ttyrec_path($g, $url->{u}));
    uncompress_ttyrec($g, $url);
    $sz += -s(ttyrec_path($g, $url->{u}));
  }

  # Do we have a ttyrec with "You die..."? If not, discard the lot.
  unless (is_death_ttyrec($g, $tofetch[-1]->{u})) {
    for my $ttyrec (@tofetch) {
      unlink ttyrec_path($g, $ttyrec->{u});
    }
    warn "Game has no death ttyrec: ", desc_game($g), "\n";
    return undef;
  }

  $g->{sz} = $sz;
  $g->{ttyrecs} = join(" ", map($_->{u}, @tofetch));
  $g->{ttyrecurls} = \@tofetch;

  1
}

sub fetch_ttyrecs {
  my $g = shift;

  # Check if we already have the game.
  if (game_was_fetched($g)) {
    print "Skipping already fetched game: ", desc_game($g), "\n";
    return;
  }

  my $start = tty_time($g, 'start');
  my $end = tty_time($g, 'end');

  my @ttyrecs = find_ttyrecs($g) or do {
    print "No ttyrecs on server for ", desc_game($g), "?\n";
    return;
  };

  @ttyrecs = grep(ttyrec_between($_->{u}, $start, $end), @ttyrecs);
  unless (@ttyrecs) {
    warn "No ttyrecs between $start and $end for ", desc_game($g), "\n";
    return;
  }

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

  return @{$CACHED_TTYREC_URLS{$userpath}} if $CACHED_TTYREC_URLS{$userpath};

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

  $CACHED_TTYREC_URLS{$userpath} = \@ttyrecs;
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

  for my $log (@LOG_URLS) {
    # Go to last point that we processed.
    my $fh = seek_log($log);
    while (my $game = read_log($fh, $log)) {

      my $good_game = interesting_game($game) && fetch_ttyrecs($game);
      $games++ if $good_game;

      $DBH->begin_work;
      record_game($game) if $good_game;
      record_log_place($log, $game);
      $DBH->commit;

      if (!(++$lines % 100)) {
        my $total = $games + $existing_games;
        print "Scanned $lines lines, found $total interesting games\n";
      }
    }
  }
}

############################  TV!  ####################################

my $SERVER      = '213.184.131.118'; # termcast server (probably don't change)
my $PORT        = 31337;             # termcast port (probably don't change)
my $NAME        = 'C_SPLAT';         # name to use on termcast
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

sub fetch_all_games {
  my $rows = exec_all("SELECT id, logrecord, ttyrecs FROM ttyrec");

  my @games;
  for my $row (@$rows) {
    my $id = $row->[0];
    my $g = xlog_line($row->[1]);
    $g->{ttyrecs} = $row->[2];
    $g->{id} = $id;
    push @games, $g;
  }
  @games
}

sub scan_ttyrec_list {
  @TVGAMES = fetch_all_games();
  die "No games to play!\n" unless @TVGAMES;
  @TVGAMES = grep(!$PLAYED_GAMES{$_->{id}}, @TVGAMES);
}

sub pick_random_unplayed {
  unless (@TVGAMES) {
    clear_played_games();
    scan_ttyrec_list();
  }
  die "No games?" unless @TVGAMES;
  my $game = $TVGAMES[int(rand(@TVGAMES))];
  record_played_game($game);
  $game
}

sub record_played_game {
  my $g = shift;

  $PLAYED_GAMES{$g->{id}} = 1;
  exec_query("INSERT INTO played_games (ref_id) VALUES (?)",
             $g->{id});
}

sub clear_played_games {
  %PLAYED_GAMES = ();
  exec_do("DELETE FROM played_games");
}

sub load_played_games {
  my $rrows = exec_all("SELECT ref_id FROM played_games");
  for my $row (@$rrows) {
    $PLAYED_GAMES{$row->[0]} = 1;
  }
}

sub run_tv {
  load_played_games();

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
    sleep 5;
    $prev = desc_game_brief($prev);
    print $SOCK "\e[2J\e[H";
    print $SOCK "That was \e[1;33m$prev.\e[0m\e[2;0H" if $prev;
  }
  print $SOCK "Now playing \e[1;33m$this\e[0m.";
  sleep($prev? 3 : 5);
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
  for my $ttyrec (split / /, $g->{ttyrecs}) {
    eval {
      tv_play_ttyrec($g, $ttyrec, $sz && $sz > $TTYRDEFSZ ? -1 : 0);
    };
    warn "$@\n" if $@;
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

sub tv_play_ttyrec {
  my ($g, $ttyrec, $skip) = @_;
  my $ttyfile = ttyrec_path($g, $ttyrec);
  server_connect();

  my $size = -s $ttyfile;
  my $skipsize = 0;

  if ($skip) {
    if ($skip > 0 && $skip < $size) {
      $skipsize = $skip;
    }
    else {
      $size *= $BZ2X if $ttyfile =~ /.bz2$/;
      if ($size > $TTYRDEFSZ * 1.5) {
        $skipsize = $size - int($TTYRDEFSZ * 1.5);
      }
    }
    print "\nNeed to skip $skipsize of $size bytes\n" if $skipsize;
  }

  print "Playing ttyrec for ", desc_game($g), " from $ttyfile\n";

  my $t = Term::TtyRec::Plus->new(infile => $ttyfile,
                                  time_threshold => 3);
  my $ttyrec_time = ttyrec_file_time($ttyfile);
  my $end_time = tty_time($g, 'end');

  my $delta = delta_seconds(DateCalc($ttyrec_time, $end_time));
  my $fc = 0;
  my $lastclear = 0;
  my $lastgoodclear = 0;
  while (my $fref = $t->next_frame()) {
    if ($skipsize) {
      my $pos = tell($t->filehandle());
      my $hasclear = index($fref->{data}, "\033[2J") > -1;
      $lastclear = $pos if $hasclear;
      $lastgoodclear = $pos
        if $hasclear && $size - $pos < $TTYRDEFSZ * 2
          && $size - $pos >= $TTYRDEFSZ;

      next if $pos < $skipsize;
      if (index($fref->{data}, "\033[2J") > -1) {
        undef $skipsize;

        my $size_left = $size - $pos;
        print "Done skip, starting normal playback\n";
      } else {
        next;
      }
    }
    select undef, undef, undef, $fref->{diff};
    print $SOCK tv_frame_strip($fref->{data});
    select undef, undef, undef, 0.5 if is_death_frame($fref->{data});
  }

  close($t->filehandle());

  if ($skipsize) {
    tv_play_ttyrec($g, $ttyrec, $lastclear);
  }
}

#######################################################################

open_db();
load_blacklist();
if ($opt{tv}) {
  run_tv();
}
elsif ($opt{migrate}) {
  migrate_paths();
}
elsif ($opt{'sanity-check'}) {
  sanity_check();
}
else {
  fetch();
}
