use strict;
use warnings;

package CSplat::Ttyrec;

use base 'Exporter';

our @EXPORT_OK = qw/$TTYRMINSZ $TTYRMAXSZ $TTYRDEFSZ $TTYREC_DIR
                    clear_cached_urls ttyrec_path url_file
                    ttyrec_file_time tty_time fetch_ttyrecs
                    update_fetched_games fetch_url record_game
                    tv_frame_strip is_death_ttyrec
                    ttyrecs_out_of_time_bounds/;

use CSplat::Config qw/$DATA_DIR $UTC_EPOCH server_field game_server/;
use CSplat::Xlog qw/fix_crawl_time game_unique_key desc_game xlog_str/;
use CSplat::DB qw/fetch_all_games exec_query in_transaction last_row_id/;
use Carp;
use Date::Manip;
use LWP::Simple;
use File::Path;

our $TTYREC_DIR = "$DATA_DIR/ttyrecs";

# Smallest cumulative length of ttyrec that's acceptable.
our $TTYRMINSZ = 95 * 1024;

# Largest cumulative length of ttyrec. The longer it gets, the harder we
# have to work to seek to the fun parts.
our $TTYRMAXSZ = 200 * 1024 * 1024;

# Default ttyrec length.
our $TTYRDEFSZ = 130 * 1024;

# Approximate compression of ttyrecs
my $BZ2X = 11;
my $GZX = 6.6;

my %CACHED_TTYREC_URLS;
my %FETCHED_GAMES;

sub url_file {
  my $url = shift;
  my ($file) = $url =~ m{.*/(.*)};
  $file
}

sub clear_cached_urls {
  %CACHED_TTYREC_URLS = ();
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
  my $status = system $command;
  die "Error fetching $url: $?\n" if $status;
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

sub record_game {
  my $game = shift;
  record_fetched_game($game);
  exec_query("INSERT INTO ttyrec (logrecord, ttyrecs)
              VALUES (?, ?)",
             xlog_str($game), $game->{ttyrecs});
  my $id = last_row_id();
  $game->{id} = $id;
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

sub fetch_ttyrecs {
  my $g = shift;

  # Check if we already have the game.
  if (game_was_fetched($g)) {
    #print "Skipping already fetched game: ", desc_game($g), "\n";
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

sub tty_tz_time {
  my ($g, $time) = @_;
  my $dst = $time =~ /D$/;
  $time =~ s/[DS]$//;

  my $tz = server_field($g, $dst? 'dsttz' : 'tz');
  ParseDate("$time $tz")
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
  ($pdate le $end) && (!$start || $pdate ge $start)
}

sub ttyrec_path {
  my ($g, $url) = @_;
  my $server = game_server($g);
  my $dir = "$TTYREC_DIR/$server/$g->{name}";
  mkpath( [ $dir ] ) unless -d $dir;
  $dir . "/" . url_file($url)
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

1;
