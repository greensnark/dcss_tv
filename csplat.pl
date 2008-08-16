#! /usr/bin/perl

use strict;
use warnings;
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

my @IPLACES = qw/Tomb Hell Dis Tar Geh Coc Vault Crypt Zot Pan/;

my $CAO_UTC_EPOCH = ParseDate("2008-08-07 03:30 UTC");
my $CAO_BEFORE = DateCalc($CAO_UTC_EPOCH, "-2 days");
my $CAO_AFTER = DateCalc($CAO_UTC_EPOCH, "+2 days");

my %SERVMAP =
  ('crawl.akrasiac.org' => { tz => 'EST',
                             ttypath => 'http://crawl.akrasiac.org/rawdata' });

my $DBH;

main();

sub main {
  check_dirs();
  init_db();
  fetch_logs(@LOG_URLS);
  trawl_games();
}

sub check_dirs {
  mkpath( [ $DATA_DIR, $TTYREC_DIR ] );
}

sub init_db {
  $DBH = open_db();
}

sub open_db {
  my $size = -s $TRAIL_DB;
  my $dbh = DBI->connect("dbi:SQLite:$TRAIL_DB");
  create_tables($dbh) unless defined($size) && $size > 0;
  $dbh
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
  $TTYREC_DIR . "/" . url_file(shift)
}

sub fetch_url {
  my ($url, $file) = @_;
  $file ||= url_file($url);
  my $command = "wget -c -O $file $url";
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
}

sub place_prefix {
  my $place = shift;
  return $place if index($place, ':') == -1;
  $place =~ s/:.*//;
  $place
}

sub is_interesting_place {
  # We're interested in Zot, Hells, Vaults, Tomb.
  my ($place, $xl) = @_;
  my $prefix = place_prefix($place);
  return if $prefix eq 'Vault' && $xl < 24;
  ($place =~ "Abyss" && $xl > 20)
    || grep($prefix eq $_, @IPLACES)
}

sub interesting_game {
  my $g = shift;

  return if $g->{ktyp} eq 'quitting';

  my $xl = $g->{xl};
  my $place = $g->{place};

  my $good = is_interesting_place($place, $xl) && $xl > 10;

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
    "after $g->{turn} turns."
}

sub download_ttyrecs {
  my $g = shift;
  print "Downloading ttyrecs for ", desc_game($g), "\n";
  for my $url (split / /, $g->{ttyrecs}) {
    fetch_url($url, ttyrec_path($url));
  }
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
  download_ttyrecs($g);

  1
}

sub clean_ttyrec_url {
  my $url = shift;
  $url->{u} =~ s{^./}{};
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
  my @urlsizes = $listing =~ /a\s+href\s*=\s*["'](.*?)["'].*([\d.]+[kM])\b/gi;
  my @urls;
  for (my $i = 0; $i < @urlsizes; $i += 2) {
    my $url = $urlsizes[$i];
    my $size = human_readable_size($urlsizes[$i + 1]);
    push @urls, { u => $url, sz => $size };
  }
  my @ttyrecs = map(clean_ttyrec_url($_), grep($_->{u} =~ /\.ttyrec/, @urls));
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
    $DBH->begin_work;
    while (my $game = read_log($fh, $log)) {
      if (interesting_game($game) && fetch_ttyrecs($game)) {
        $games++;
        record_game($game);
      }
      record_log_place($log, $game);

      if (!(++$lines % 100)) {
        print "Scanned $lines lines, found $games interesting games\n";
        $DBH->commit;
        $DBH->begin_work;
      }

      if ($games + $existing_games > 3) {
        start_ttyplay();
      }
    }
    $DBH->commit;
  }
}
