use strict;
use warnings;

package CSplat::Ttyrec;

use lib '..';
use base 'Exporter';

our @EXPORT_OK = qw/$TTYRMINSZ $TTYRMAXSZ $TTYRDEFSZ
                    clear_cached_urls ttyrec_path url_file
                    ttyrec_file_time tty_time fetch_ttyrecs
                    update_fetched_games fetch_url record_game
                    tv_frame_strip is_death_ttyrec
                    ttyrecs_out_of_time_bounds request_download
                    request_cache_clear/;

use CSplat::Config qw/$DATA_DIR $TTYREC_DIR $UTC_EPOCH
                      $FETCH_PORT server_field game_server
                      resolve_canonical_game_version/;
use CSplat::Xlog qw/fix_crawl_time game_unique_key desc_game xlog_str
                    xlog_line xlog_merge/;
use CSplat::DB qw/fetch_all_games exec_query in_transaction last_row_id/;
use CSplat::TtyrecList;
use Carp;
use Date::Manip;
use LWP::Simple;
use File::Path;
use IO::Socket::INET;
use Term::TtyRec::Plus;

# Smallest cumulative length of ttyrec that's acceptable.
our $TTYRMINSZ = 95 * 1024;

# Largest cumulative length of ttyrec. The longer it gets, the harder we
# have to work to seek to the fun parts.
our $TTYRMAXSZ = 500 * 1024 * 1024;

# Default ttyrec length.
our $TTYRDEFSZ = 130 * 1024;

# Approximate compression of ttyrecs
my $BZ2X = 11;
my $GZX = 6.6;

my %CACHED_TTYREC_URLS;
my %FETCHED_GAMES;

my @FETCH_LISTENERS;

sub add_fetch_listener {
  push @FETCH_LISTENERS, @_;
}

sub clear_fetch_listeners {
  @FETCH_LISTENERS = ();
}

sub notify_fetch_listeners {
  warn "Notify: ", @_, "\n";
  $_->(@_) for @FETCH_LISTENERS;
}

sub url_file {
  my $url = shift;
  my ($file) = $url =~ m{.*/(.*)};
  $file
}

sub clear_cached_urls {
  %CACHED_TTYREC_URLS = ();
}

sub have_cached_listing_for_game {
  my $g = shift;
  my $path = find_game_ttyrec_list_path($g);
  $CACHED_TTYREC_URLS{$path}
}

sub clear_cached_urls_for_game {
  my $g = shift;
  my $path = find_game_ttyrec_list_path($g);
  delete $CACHED_TTYREC_URLS{$path};
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

sub fetch_url {
  my ($url, $file) = @_;
  $file ||= url_file($url);
  my $command = "wget -q -c -O $file $url";
  my $status = system($command);
  die "Error fetching $url: $?\n" if ($status >> 8);
}

sub download_ttyrecs {
  my ($g, $no_checks) = @_;

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

  if ($sz > $TTYRMAXSZ || (!$no_checks && $sz < $TTYRMINSZ)) {
    print "ttyrec total size for " . desc_game($g) .
      " = $sz is out of bounds.\n";
    return;
  }

  @tofetch = reverse(@tofetch);
  print "Downloading ", scalar(@tofetch), " ttyrecs for ", desc_game($g), "\n";
  $sz = 0;
  for my $url (@tofetch) {
    notify_fetch_listeners("Downloading $url->{u}...");
    my $path = ttyrec_path($g, $url->{u});
    fetch_url($url->{u}, ttyrec_path($g, $url->{u}));
    uncompress_ttyrec($g, $url);
    $sz += -s(ttyrec_path($g, $url->{u}));
  }

  # Do we have a ttyrec with "You die..."? If not, discard the lot.
  unless ($no_checks || is_death_ttyrec($g, $tofetch[-1]->{u})) {
    for my $ttyrec (@tofetch) {
      unlink ttyrec_path($g, $ttyrec->{u});
    }
    notify_fetch_listeners("Game has no death ttyrec: " . desc_game($g));
    return undef;
  }

  $g->{sz} = $sz;
  $g->{ttyrecs} = join(" ", map($_->{u}, @tofetch));
  $g->{ttyrecurls} = \@tofetch;

  for my $ttyrec (split / /, $g->{ttyrecs}) {
    register_ttyrec($g, $ttyrec);
  }

  1
}

sub record_game {
  my ($game, $splat) = @_;

  die "Must specify splattiness\n" unless defined $splat;

  my $req = $game->{req};
  delete $game->{req} if $req;
  record_fetched_game($game);

  exec_query("INSERT INTO games (src, player, gtime, logrecord, ttyrecs, etype)
              VALUES (?, ?, ?, ?, ?, ?)",
             $game->{src}, $game->{name}, $game->{end} || $game->{time},
             xlog_str($game), $game->{ttyrecs}, $splat);
  my $id = last_row_id();
  $game->{req} = $req;
  $game->{id} = $id;
}

# Registers a ttyrec if it is not already registered.
sub check_register_ttyrec {
  my ($g, $ttyrec) = @_;
  my $row =
    CSplat::DB::exec_query_all('SELECT * FROM ttyrec WHERE ttyrec = ?',
                               $ttyrec);
  if (!$row || @$row == 0) {
    print "Registering ttyrec $ttyrec\n";
    register_ttyrec($g, $ttyrec);
  }
}

sub ttyrec_play_time {
  my ($g, $ttyrec, $seektime) = @_;

  my $file = ttyrec_path($g, $ttyrec);

  my $start = ttyrec_file_time($ttyrec);
  my $t = Term::TtyRec::Plus->new(infile => $file);

  my $last_ts;
  my $first_ts;

  my $seekdelta =
    $seektime ? int(Delta_Format(DateCalc($start, $seektime), 0, '%st'))
              : undef;

  my $pframe;
  my $frame;
  my $seek_frame_offset;
  my $last_frame_offset;
  eval {
    while (my $fref = $t->next_frame()) {
      $frame = tell($t->filehandle()) if $seekdelta;

      my $ts = $fref->{orig_timestamp};
      $first_ts = $ts unless defined $first_ts;
      $last_ts = $ts;

      $last_frame_offset = $pframe || $frame;
      if (defined($seekdelta) && !$seek_frame_offset
          && $last_ts - $first_ts >= $seekdelta)
      {
        $seek_frame_offset = $last_frame_offset;
      }

      $pframe = $frame;
    }
  };
  warn "$@" if $@;

  if (defined($seekdelta) && !defined($seek_frame_offset)) {
    $seek_frame_offset = $last_frame_offset;
  }

  return (undef, undef, undef) unless defined $first_ts;

  my $delta = int($last_ts - $first_ts);
  my $end = DateCalc($start, "+ $delta seconds");

  ($start, $end, $seek_frame_offset)
}

sub register_ttyrec {
  my ($g, $ttyrec, $seektime) = @_;
  my ($start, $end, $seek_offset) = ttyrec_play_time($g, $ttyrec, $seektime);

  eval {
    # First kill any existing registration.
    exec_query('DELETE FROM ttyrec WHERE ttyrec = ?', $ttyrec);
  };

  eval {
    exec_query('INSERT INTO ttyrec (ttyrec, src, player, stime, etime)
                VALUES (?, ?, ?, ?, ?)',
               $ttyrec, $g->{src}, $g->{name}, $start, $end);
  };
  warn $@ if $@;
  $seek_offset
}

sub unregister_ttyrec {
  my ($g, $ttyrec) = @_;
  exec_query('DELETE FROM ttyrec WHERE ttyrec = ?', $ttyrec)
}

sub record_fetched_game {
  my $g = shift;
  $FETCHED_GAMES{game_unique_key($g)} = $g;
}

sub update_fetched_games {
  %FETCHED_GAMES = ();
  my @games = fetch_all_games(splat => '*');
  for my $g (@games) {
    record_fetched_game($g);
  }
}

sub game_was_fetched {
  my $g = shift;
  $FETCHED_GAMES{game_unique_key($g)}
}

sub find_existing_ttyrec {
  my ($g, $end) = @_;
  CSplat::DB::query_one("SELECT ttyrec FROM ttyrec
                         WHERE src = ? AND player = ?
                           AND stime <= ? AND etime >= ?",
                        $g->{src}, $g->{name}, $end, $end)
}

sub fetch_ttyrecs {
  my ($g, $no_death_check) = @_;

  # Check if we already have the game.
  my $fetched = game_was_fetched($g);
  if ($fetched) {
    my $clone = { %$fetched };
    delete $$clone{seekbefore};
    delete $$clone{seekafter};
    return xlog_merge($g, $clone);
  }

  my $start = tty_time($g, 'start');
  my $end = tty_time($g, 'end');
  $end ||= tty_time($g, 'time');

  my @ttyrecs;

  # If we have only an end time, look for an existing ttyrec that
  # covers this time.
  if (!$start && $end) {
    my $ttyrec = find_existing_ttyrec($g, $end);
    if ($ttyrec) {
      push @ttyrecs, $ttyrec;

      # Early exit.
      $g->{ttyrecs} = $ttyrec;
      $g->{ttyrecurls} = \@ttyrecs;
      $g->{sz} = -s(ttyrec_path($g, $ttyrec));
      return $g;
    }
  }

  @ttyrecs = find_ttyrecs($g) or do {
    print "No ttyrecs on server for ", desc_game($g), "?\n";
    return;
  };

  @ttyrecs = grep(ttyrec_between($_->{u}, $start, $end), @ttyrecs);
  unless (@ttyrecs) {
    warn "No ttyrecs between $start and $end for ", desc_game($g), "\n";
    return;
  }

  # If no start time, restrict to one ttyrec.
  @ttyrecs = ($ttyrecs[-1]) unless $start;

  $g->{ttyrecs} = join(" ", map($_->{u}, @ttyrecs));
  $g->{ttyrecurls} = \@ttyrecs;
  download_ttyrecs($g, $no_death_check)
}

sub fetch_ttyrec_urls_from_server {
  my ($name, $userpath, $time_wanted) = @_;

  my $now = time();
  my $cache = $CACHED_TTYREC_URLS{$userpath};
  return @{$cache->[1]} if $cache && $cache->[0] >= $time_wanted;

  notify_fetch_listeners("Fetching ttyrec listing from " . $userpath . "...");

  my $rttyrecs = CSplat::TtyrecList::fetch_listing($name, $userpath);
  $rttyrecs = [] unless defined $rttyrecs;

  $CACHED_TTYREC_URLS{$userpath} = [ $now, $rttyrecs ];
  @$rttyrecs
}

sub find_game_ttyrec_list_path {
  my $g = shift;
  my $servpath = server_field($g, 'ttypath');
  my $userpath = resolve_canonical_game_version("$servpath/$g->{name}", $g);
  return $userpath;
}

sub find_ttyrecs {
  my $g = shift;

  my $ttyrecurl = find_game_ttyrec_list_path($g);
  my $end = tty_time($g, 'end') || tty_time($g, 'time');
  my $time = int(UnixDate($end, "%s"));
  my @urls = fetch_ttyrec_urls_from_server($g->{name}, $ttyrecurl, $time);
  @urls
}

sub tty_tz_time {
  my ($g, $time) = @_;
  my $dst = $time =~ /D$/;
  $time =~ s/[DS]$//;

  my $tz = server_field($g, $dst? 'dsttz' : 'tz');
  ParseDate("$time $tz")
}

sub tty_time {
  my ($g, $which) = @_;

  my $raw = $g->{$which};
  return unless $raw;

  my $time = fix_crawl_time($raw);
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
  if ($date) {
    $date =~ tr/./ /;
    return ParseDate("$date UTC");
  }

  if ($url =~ /(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+][\d:]+)/) {
    return ParseDate($1);
  }

  die "ttyrec url ($url) contains no date?\n";
}

sub ttyrec_between {
  my ($tty, $start, $end) = @_;
  my $pdate = ttyrec_file_time( $tty );
  ($pdate le $end) && (!$start || $pdate ge $start)
}

sub ttyrec_path {
  my ($g, $url) = @_;
  my $server = game_server($g);
  my $dir = "$TTYREC_DIR/$server/$g->{name}";
  mkpath( [ $dir ] ) unless -d $dir;
  $dir . "/" . url_file($url)
}

sub _strip_dec {
  my $text = shift;
  $text =~ tr[\x61\x60\x7e\x6e\x7b\xb6\xa7\xbb\xab\xa8][#*.+_\\}~{{];
  $text
}

sub tv_frame_strip {
  my $rdat = shift;

  # Strip DEC graphics. Still get odd glitches at times, but way
  # better than no DEC stripping.
  $rdat =~ s/(\x0e)([^\x0f]+)/ $1 . _strip_dec($2) /ge;
  $rdat =~ s/\xe2\x97\x86/*/g;

  # Strip IBM graphics.
  $rdat =~ tr/\xB1\xB0\xF9\xFA\xFE\xDC\xEF\xF4\xF7/#*.,+_\\}~/;
  $rdat =~ tr/\x0e\x0f//d;

  # Strip unicode. Rather pricey :(
  $rdat =~ s/\xe2\x96\x92/#/g;
  $rdat =~ s/\xe2\x96\x91/*/g;
  $rdat =~ s/\xc2\xb7/./g;
  $rdat =~ s/\xe2\x97\xa6/,/g;
  $rdat =~ s/\xe2\x97\xbc/+/g;
  $rdat =~ s/\xe2\x88\xa9/\\/g;
  $rdat =~ s/\xe2\x8c\xa0/}/g;
  $rdat =~ s/\xe2\x89\x88/~/g;

  $rdat
}

sub fetch_request {
  my $sub = shift;

  my $tries = 25;
  # Open connection and make request.
  while ($tries-- > 0) {
    my $sock = IO::Socket::INET->new(PeerAddr => 'localhost',
                                     PeerPort => $FETCH_PORT,
                                     Type => SOCK_STREAM,
                                     Timeout => 15);
    unless ($sock) {
      # The fetch server doesn't seem to be running, try starting it.
      system "perl fetch.pl";
      # Give it a little time to get moving.
      sleep 1;
    }
    else {
      return $sub->($sock);
    }
  }
  die "Failed to connect to fetch server\n";
}

sub request_cache_clear {
  fetch_request(
    sub {
      my $sock = shift;
      print $sock "CLEAR\n";
      my $res = <$sock>;
      $res =~ /OK/
    } )
}

sub request_download {
  my ($g, $listener) = @_;
  fetch_request( sub { send_download_request(shift, $g, $listener) } )
}

sub send_download_request {
  my ($sock, $g, $listener) = @_;
  print $sock "G " . xlog_str($g) . "\n";

  while (my $response = <$sock>) {
    if ($response =~ /^S (.*)/) {
      chomp(my $text = $1);
      $listener->($text) if $listener;
      next;
    }

    return undef unless ($response || '') =~ /OK/;

    chomp $response;
    my ($xlog) = $response =~ /^OK (.*)/;
    xlog_merge($g, xlog_line($xlog));
  }
  1
}

1;
