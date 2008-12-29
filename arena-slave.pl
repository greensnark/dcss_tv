#! /usr/bin/perl

use strict;
use warnings;

use Cwd;

use POSIX qw/setsid/;
use Fcntl qw/SEEK_SET/;

use IO::Pty::Easy;
use CSplat::Termcast;

use Getopt::Long;

use threads;
use threads::shared;

my @queued_fights : shared;
my @queued_cancels : shared;
my $current_fight;

local $SIG{CHLD} = sub { };

my %opt;
GetOptions(\%opt, 'local', 'req=s');

my $CRAWL_HOME = $ENV{CRAWL_HOME} or die "CRAWL_HOME must be set!\n";
my $ARENA_REQ_FILE = $opt{req} or die "request filename not specified";
open my $AR, '<', $ARENA_REQ_FILE or die "Cannot open $ARENA_REQ_FILE: $!";

daemonize() unless $opt{local};

my $TV = CSplat::Termcast->new(name => 'FightClubCrawl',
                               passfile => 'fightclub.pwd',
                               local => $opt{local});

wait_for_requests();

sub daemonize {
  umask 0;
  defined(my $pid = fork()) or die "Unable to fork: $!";

  # Parent dies now.
  exit if $pid;

  setsid or die "Unable to start a new session: $!"
}

sub wait_for_requests {
  my $termc = threads->new(\&arena_tv);
  $termc->detach;

  while (1) {
    sleep 1;

    my $pos = tell($AR);
    my $req = <$AR>;

    # If we don't have a complete line, seek back to where we started
    # and retry.
    if (!defined($req) || $req !~ /\n$/) {
      seek($AR, $pos, SEEK_SET);
      next;
    }

    s/\s+$//, s/^\s+// for $req;

    if ($req =~ /^(\S+): (.*)/) {
      run_arena($1, $2);
    }
  }
}

sub run_arena {
  my ($who, $what) = @_;
  if (lc($what) !~ /\bcancel\b/) {
    push @queued_fights, "$who: $what";
  }
  else {
    $what =~ s/\bcancel\b//;
    push @queued_cancels, $what;
  }
}

sub announce_arena {
  $TV->clear();
  $TV->write("\e[1H\e[1;34mFight Club\e[0m\e[2H");
  $TV->write("Use !fight on ##crawl to make a request\e[3H");
}

sub arena_tv {
  announce_arena();
  while (1) {
    sleep 1;
    next unless @queued_fights || @queued_cancels;
    handle_cancels();

    my $fight = shift @queued_fights;
    next unless $fight;

    play_fight($fight);

    $TV->reset();
    announce_arena();
  }
}

sub strip_space {
  my $text = shift;
  s/^\s+//, s/\s+$//, s/\s+/ /g for $text;
  $text
}

sub handle_cancels {
  return unless @queued_cancels;

  my $cancel_current;
  my @cancels = @queued_cancels;
  @queued_cancels = ();
  for my $cancel (@cancels) {
    if ($cancel eq 'cancel') {
      @queued_fights = ();
      return 1;
    }
    my $stripped = lc(strip_space($cancel));
    @queued_fights = grep(lc(strip_space($_)) ne $stripped, @queued_fights);
    $cancel_current = 1 if lc(strip_space($current_fight)) eq $stripped;
  }
  $cancel_current
}

sub play_fight {
  my $fight = shift;

  my ($who, $what) = $fight =~ /^(\S+): (.*)/;

  $current_fight = $what;

  my $pty = IO::Pty::Easy->new;

  my $dir = getcwd();
  chdir "$CRAWL_HOME/source";

  $what =~ tr/'//d;
  $pty->spawn("./crawl -arena '$what'");

  while ($pty->is_active) {
    if (handle_cancels()) {
      $pty->kill('TERM', undef);
      last;
    }

    my $read = $pty->read(1);
    next unless defined $read;

    last if length($read) == 0;
    $TV->write($read);
  }
  $pty->close();

  undef $current_fight;
}
