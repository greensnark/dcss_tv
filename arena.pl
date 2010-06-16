#! /usr/bin/perl

use strict;
use warnings;

use IO::Handle;
use Getopt::Long;

# The plot:
# 1) wait for requests on IRC
# 2) on request, fork and play request, or queue request.
# 3) cancels blow the whole playlist.

my $CRAWL_HOME = $ENV{CRAWL_HOME} or die "CRAWL_HOME must be set!\n";
my $ARENA_REQ_FILE = 'arena.req';

my $ARENA_IRC_PASSFILE = 'arenairc.pwd';

my $IRCSERVER = 'irc.freenode.net';
my $IRCNICK = 'varmin';
my $IRCNAME = 'Varmin the sexy verminbot';
my $IRCPORT = 6667;

my @CHANNELS = ('##crawl', '##crawl-dev');

our $IRC;
our $LOGCRAWL;
our $LOGCRAWLDEV;

my %LOGCHANNEL = ('##crawl' => [ 'irc-crawl.log' ],
                  '##crawl-dev' => [ 'irc-crawl-dev.log' ],
                  'msg' => [ 'irc-msg.log' ]);

local $SIG{CHLD} = sub { };

my %opt;
GetOptions(\%opt, 'local', 'req=s');

open my $REQH, '>', $ARENA_REQ_FILE or die "Could not open $ARENA_REQ_FILE: $!";

# Start the slave that plays requests.

run_slave();
do_irc();

sub run_slave {
  my $pid = fork;
  die "Unable to fork!" unless defined $pid;

  # Parent does IRC, child does the pty.
  return if $pid;

  my @args = ('./arena-slave.pl', '--req', $ARENA_REQ_FILE);
  push @args, '--local' if $opt{local};
  exec(@args);
  exit 0;
}

sub do_irc {
  for my $chan (keys %LOGCHANNEL) {
    my $flog = $LOGCHANNEL{$chan};
    open my $file, '>>', $$flog[0] or die "Can't open: $$flog[0]: $!\n";
    push @$flog, $file;
  }

  $IRC = Varmin->new(nick => $IRCNICK,
                     server => $IRCSERVER,
                     port => $IRCPORT,
                     ircname => $IRCNAME,
                     channels => [ @CHANNELS ])
    or die "Unable to connect to $IRCSERVER: $!";
  $IRC->run();
}

sub chomped_line {
  my $fname = shift;
  if (-r $fname) {
    open my $inf, '<', $fname or return undef;
    chomp(my $contents = <$inf>);
    return $contents;
  }
  undef
}

sub clean_response {
  my $text = shift;
  length($text) > 400? substr($text, 0, 400) : $text
}

sub log_irc {
  my ($m, $line) = @_;

  my $log = ${$LOGCHANNEL{$$m{channel}}}[1];
  if ($log) {
    chomp $line;
    print $log "[" . scalar(gmtime()) . "] $line\n";
    $log->flush;
  }
}

sub process_msg {
  my ($m) = @_;
  my $nick = $$m{who};
  my $channel = $$m{channel};

  my $body = $$m{body};
  if ($body =~ /^!fight (.*)/i) {
    print "Fight request: $1 by $nick\n";
    run_arena($nick, $1);
  }
}

sub run_arena {
  my ($nick, $what) = @_;
  print $REQH "$nick: $what\n";
  $REQH->flush();
}

package Varmin;
use base 'Bot::BasicBot';

sub connected {
  my $self = shift;

  my $password = main::chomped_line($ARENA_IRC_PASSFILE);
  if ($password) {
    $self->say(channel => 'msg',
               who => 'nickserv',
               body => "identify $password");
  }
  return undef;
}

sub emoted {
  my ($self, $e) = @_;
  main::log_irc($e, "* $$e{who} $$e{body}");
  return undef;
}

sub said {
  my ($self, $m) = @_;
  main::log_irc($m, "$$m{who}: $$m{body}");
  main::process_msg($m);
  return undef;
}

sub chanjoin {
  my ($self, $j) = @_;
  main::log_irc($j, "-|- $$j{who} has joined $$j{channel}");
  return undef;
}

sub userquit {
  my ($self, $q) = @_;
  main::log_irc($q, "-|- $$q{who} has quit [$$q{body}]");
  return undef;
}

sub chanpart {
  my ($self, $m) = @_;
  main::log_irc($m, "-|- $$m{who} has left $$m{channel}");
  return undef;
}
