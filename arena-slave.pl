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

my @bad_requests;
my @fight_results;

my $current_fight;
my $MIN_DELAY = 25;
my $MAX_FIGHT_TIME_SECONDS = 10;

local $SIG{CHLD} = sub { };

# Force canonical term size.
$ENV{LINES} = 24;
$ENV{COLUMNS} = 80;

my %opt;
GetOptions(\%opt, 'local', 'req=s');

my $CRAWL_HOME = $ENV{CRAWL_HOME} or die "CRAWL_HOME must be set!\n";
my $ARENA_REQ_FILE = $opt{req} or die "request filename not specified";

my $ARENA_RESULT = 'arena.result';

open my $AR, '<', $ARENA_REQ_FILE or die "Cannot open $ARENA_REQ_FILE: $!";

my $TV = CSplat::Termcast->new(name => 'FightClub',
                               passfile => 'fightclub.pwd',
                               local => $opt{local});

wait_for_requests();

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
    push @queued_cancels, $what;
  }
}

sub show_errors {
  return unless @bad_requests;
  $TV->write("\e[1;31mErrors\e[0m\r\n");
  for my $err (@bad_requests) {
    $TV->write("$err\r\n");
  }
  $TV->write("\r\n");
  @bad_requests = ();
}

sub show_queue {
  my @fights = @queued_fights;
  unless (@fights) {
    $TV->title("[waiting]");
    return;
  }

  @fights = @fights[0 .. 4] if @fights > 5;

  $TV->write("\e[1;37mComing up\e[0m\r\n");
  my $first = 0;
  for my $fight (@fights) {
    $TV->write("$fight\r\n");
  }
  $TV->write("\r\n");
}

sub show_results {
  my $max = 10 - @queued_fights;
  $max = 5 if $max < 5;

  my @results = reverse @fight_results;
  return unless @results;

  @results = @results[0 .. ($max - 1)] if @results > $max;

  $TV->write("\e[1;32mPrevious Fights\e[0m\r\n");
  for my $res (@results) {
    $TV->write(sprintf("%-7s %s {%s}\r\n",
                       $res->[1], $res->[0], $res->[2]));
  }
  $TV->write("\r\n");
}

sub announce_arena {
  $TV->clear();
  $TV->write("\e[1H\e[1;34mFight Club\e[0m\r\n");
  $TV->write("Use !fight on ##crawl to make a request\r\n\r\n");

  show_errors();
  show_queue();
  show_results();
}

sub arena_tv {
  announce_arena();
  while (1) {
    sleep 1;
    next unless @queued_fights || @queued_cancels;
    announce_arena();
    handle_cancels();

    my $fight = shift @queued_fights;
    next unless $fight;

    play_fight($fight);
    $TV->reset();
    announce_arena();

    sleep 1 if @bad_requests;
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
    $cancel =~ s/\bcancel\b//g;
    my $stripped = lc(strip_space($cancel));
    @queued_fights = grep(lc(strip_space($_)) ne $stripped, @queued_fights);
    $cancel_current = 1 if lc(strip_space($current_fight)) eq $stripped;
  }
  $cancel_current
}

sub strip_junk {
  my $text = shift;
  for ($text) {
    s/\bno_summons\b//g;

    s/\s+/ /g;
  }
  $text
}

sub get_qualifiers {
  my $term = shift;

  my @quals;
  if ($term =~ /\b(no_summons)\b/) {
    push @quals, $1;
  }
  @quals
}

sub record_arena_result {
  my $who = shift;

  return unless -f $ARENA_RESULT;

  open my $inf, '<', $ARENA_RESULT or return;
  my $fight_spec = <$inf>;

  if ($fight_spec =~ /^err: (.*)$/) {
    push @bad_requests, $1;
    return;
  }

  my $line = <$inf>;
  return unless $line && $line =~ /\n$/;

  chomp $line;

  if ($line =~ /^(\d+)-(\d+)$/) {
    my ($a, $b) = ($1, $2);

    my (@teams) = map(strip_space($_),
                      split(/ v /, strip_junk($current_fight)));

    my @qualifiers = get_qualifiers($current_fight);
    return unless @teams == 2;

    my $name = join(" v ", $b > $a ? reverse(@teams) : @teams);
    my $result = $b > $a ? "$b - $a" : "$a - $b";

    $name = "$name (" . join(", ", @qualifiers) . ")" if @qualifiers;
    push @fight_results, [ $name, $result, $who ];
  }
}

sub fight_ok {
  my ($who, $what) = @_;
  if ($what =~ /delay:0/i && $what =~ /test\s+spawner/i) {
    push @bad_requests, "$what: no test spawners with delay:0, kthx.";
    return undef;
  }
  1
}

sub play_fight {
  my $fight = shift;

  my ($who, $what) = $fight =~ /^(\S+): (.*)/;

  return unless fight_ok($who, $what);

  $current_fight = $what;

  # Get rid of low-delay CPU-wastage.
  $what =~ s/delay:(\d+)/ "delay:" . ($1 < $MIN_DELAY ? $MIN_DELAY : $1) /ge;

  $TV->clear();
  $TV->title("$current_fight");

  my $pty = IO::Pty::Easy->new;

  my $home_dir = getcwd();
  chdir "$CRAWL_HOME/source";

  unlink $ARENA_RESULT;

  $pty->spawn("./crawl", "-arena", $what);

  my $fight_started_at = time;
  my $fight_too_long;
  while ($pty->is_active) {
    if ((time - $fight_started_at) > $MAX_FIGHT_TIME_SECONDS) {
      $fight_too_long = 1;
      last;
    }
    if (handle_cancels()) {
      kill 9 => $pty->pid() if $pty->pid();
      last;
    }

    my $read = $pty->read(1);
    next unless defined $read;

    last if length($read) == 0;
    $TV->write($read);
  }
  kill 9 => $pty->pid() if $pty->pid();
  $pty->close();

  if ($fight_too_long) {
    $TV->reset();
    $TV->write("\"$what\" exceeded the time limit of ${MAX_FIGHT_TIME_SECONDS}s");
    sleep 4;
  }

  record_arena_result($who);

  # XXX: Don't really need this.
  chdir $home_dir;

  undef $current_fight;
}
