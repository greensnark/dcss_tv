#! /usr/bin/perl

use strict;
use warnings;

use IO::Handle;
use POE qw/Component::IRC Component::IRC::Plugin::NickReclaim/;
use Getopt::Long;

# The plot:
# 1) wait for requests on IRC
# 2) on request, fork and play request, or queue request.
# 3) cancels blow the whole playlist.

my $CRAWL_HOME = $ENV{CRAWL_HOME} or die "CRAWL_HOME must be set!\n";
my $ARENA_REQ_FILE = 'arena.req';

my $ARENA_IRC_PASSFILE = 'arenairc.pwd';

my $IRCSERVER = 'irc.freenode.net';
my $IRCCHAN = '##crawl';
my $IRCNICK = 'varmin';
my $IRCNAME = 'Varmin the sexy verminbot';
my $IRCPORT = 8001;

our $IRC;
our $IRCLOG;

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
  open $IRCLOG, '>>', 'irc.log';

  $IRC = POE::Component::IRC->spawn(
              nick => $IRCNICK,
              server => $IRCSERVER,
              port => $IRCPORT,
              ircname => $IRCNAME )
    or die "Unable to connect to $IRCSERVER: $!";
  POE::Session->create(
      package_states => [
                         main => [ qw/_start irc_001 irc_public irc_msg
                                     irc_255/ ]
                         ],
      heap => { irc => $IRC });
  $poe_kernel->run();
}

sub _start {
  my ($kernel,$heap) = @_[KERNEL,HEAP];

  print "START: connecting to $IRCSERVER\n";
  # We get the session ID of the component from the object
  # and register and connect to the specified server.
  my $irc_session = $heap->{irc}->session_id();
  $kernel->post( $irc_session => register => 'all' );
  $IRC->plugin_add( NickReclaim =>
   	POE::Component::IRC::Plugin::NickReclaim->new( poll => 30 ));
  $kernel->post( $irc_session => connect => { } );
  undef;
}

sub irc_001 {
  my ($kernel,$sender) = @_[KERNEL,SENDER];

  # Get the component's object at any time by accessing the heap of
  # the SENDER
  my $poco_object = $sender->get_heap();
  print "Connected to ", $poco_object->server_name(), "\n";

  # In any irc_* events SENDER will be the PoCo-IRC session
  $kernel->post( $sender => join => $IRCCHAN );
  undef;
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

sub irc_255 {
  my $password = chomped_line($ARENA_IRC_PASSFILE);
  if ($password) {
    $IRC->yield(privmsg => nickserv => "identify $password");
  }
}

sub clean_response {
  my $text = shift;
  length($text) > 400? substr($text, 0, 400) : $text
}

sub log_irc {
  if ($IRCLOG) {
    my ($private, $chan, $nick, $verbatim) = @_;
    chomp $verbatim;
    my $pm = $private ? " (pm)" : "";
    print $IRCLOG "[" . scalar(gmtime()) . "] $nick$pm: $verbatim\n";
    $IRCLOG->flush;
  }
}

sub process_msg {
  my ($private, $kernel, $sender, $who, $where, $verbatim) = @_;
  my $nick = (split /!/, $who)[0];

  my $channel = $where->[0];

  log_irc($private, $channel, $nick, $verbatim);

  my $response_to = $private ? $nick : $channel;
  if ($verbatim =~ /^!fight (.*)/i) {
    print "Fight request: $1 by $nick\n";
    run_arena($nick, $1);
    #$kernel->post($sender => privmsg => $response_to =>
    #              clean_response("Fight: $1"));
  }
}

sub irc_public {
  process_msg(0, @_[KERNEL, SENDER, ARG0, ARG1, ARG2]);
}

sub irc_msg {
  process_msg(1, @_[KERNEL, SENDER, ARG0, ARG1, ARG2]);
}

sub run_arena {
  my ($nick, $what) = @_;
  print $REQH "$nick: $what\n";
  $REQH->flush();
}
