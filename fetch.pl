#! /usr/bin/perl

# Fetch daemon.

use strict;
use warnings;

use threads;
use threads::shared;

use Fcntl qw/LOCK_EX/;
use IO::Socket::INET;
use IO::Handle;

use CSplat::Util qw/run_service/;
use CSplat::Config qw/$FETCH_PORT/;
use CSplat::Ttyrec qw/clear_cached_urls fetch_ttyrecs/;
use CSplat::Seek qw/tty_frame_offset/;
use CSplat::Select qw/interesting_game/;
use CSplat::Xlog qw/xlog_hash xlog_str desc_game/;

use POSIX;

my $MAX_REQUEST_COUNT = 279;

my $live_thread_count :shared = 0;

my $lastsync;

local $| = 1;

main();

sub main {
  run_autovacuum();
  run_service('fetch', \&run_fetch);
}

sub run_autovacuum {
  my $pid = fork;
  return if $pid;
  exec("perl vacuum.pl");
  exit 0;
}

sub run_fetch {
  my $server = IO::Socket::INET->new(LocalPort => $FETCH_PORT,
                                     Type => SOCK_STREAM,
                                     Reuse => 1,
                                     Listen => 5)
    or die "Couldn't open server socket on $FETCH_PORT: $@\n";

  # Since the shared thread variables seem to leak, set a max request count.
  my $max_requests = $MAX_REQUEST_COUNT;
  while ((my $client = $server->accept()) && $max_requests-- > 0) {
    ++$live_thread_count;
    my $thread = threads->new(sub {
      eval {
        process_command($client);
      };
      --$live_thread_count if $live_thread_count > 0;
      warn "$@" if $@;
    });
    $thread->detach;
  }
  if ($max_requests < 0) {
    print "Fulfilled $MAX_REQUEST_COUNT requests, exiting\n";
  }

  $server->close();

  while ($live_thread_count > 0) {
    sleep 2;
    print "Waiting for fetch threads to exit\n";
  }
  print "All threads completed, shutting down.\n";
}

sub process_command {
  my $client = shift;
  my $command = <$client>;
  chomp $command;
  my ($cmd) = $command =~ /^(\w+)/;
  return unless $cmd;

  if ($cmd eq 'G') {
    my ($game) = $command =~ /^\w+ (.*)/;

    my $g = xlog_hash($game);
    my $have_cache = CSplat::Ttyrec::have_cached_listing_for_game($g);

    my $res;
    eval {
      $res = fetch_game($client, $game)
    };
    warn "$@" if $@;
    if ($@ && $have_cache) {
      CSplat::Ttyrec::clear_cached_urls_for_game($g);
      eval {
        $res = fetch_game($client, $game);
      };
      warn "$@" if $@;
    }

    if ($@) {
      print $client "FAIL $@\n";
    }
    $res
  }
  elsif ($cmd eq 'CLEAR') {
    clear_cached_urls();
    print $client "OK\n";
  }
}

sub fetch_notifier {
  my ($client, $g, @event) = @_;
  my $text = join(" ", @event);
  eval {
    print $client "S $text\n";
  };
  warn $@ if $@;
}

sub fetch_game {
  my ($client, $g) = @_;

  print "Requested download: $g\n";

  my $listener = sub {
    fetch_notifier($client, $g, @_);
  };

  $g = xlog_hash($g);

  my $start = $g->{start};
  my $nocheck = $g->{nocheck};
  delete $g->{nocheck};
  delete @$g{qw/start nostart/} if $g->{nostart};
  my $result = fetch_ttyrecs($listener, $g, $nocheck);
  $g->{start} = $start;
  if ($result) {
    my $dejafait = $g->{id};
    if ($dejafait) {
      print "Not redownloading ttyrecs for ", desc_game($g), "\n";
    }
    else {
      print "Downloaded ttyrecs for ", desc_game($g), " ($g->{ttyrecs})\n";
    }

    if ($@) {
      warn $@;
      CSplat::DB::delete_game($g);
      print $client "FAIL $@\n";
    }
    else {
      print $client "OK " . xlog_str($g, 1) . "\n";
    }
  } else {
    print "Failed to download ", desc_game($g), "\n";
    die "Failed to download game\n";
  }
}
