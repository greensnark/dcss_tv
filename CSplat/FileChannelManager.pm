package CSplat::FileChannelManager;

use strict;
use warnings;

use lib '..';
use POSIX ":sys_wait_h";
use Fcntl qw/LOCK_EX SEEK_END/;
use CSplat::Channel;
use CSplat::Xlog;
use threads::shared;

my %CHANNEL_MAP :shared;

sub new {
  my ($cls, $channel_launcher) = @_;
  purge_request_files();
  bless { channel_launcher => $channel_launcher }, $cls
}

sub purge_request_files {
  CSplat::Channel::purge_request_files();
}

sub request_channel_name {
  my $g = shift;
  my $chan = $g->{channel};
  return $chan if CSplat::Channel::valid_channel_name($chan);
  CSplat::Xlog::game_channel_name($g)
}

sub game_request {
  my ($self, $g) = @_;
  my $channel = request_channel_name($g);
  CSplat::Channel::create_channel_directory();
  my $channel_file = CSplat::Channel::channel_req_file($channel);

  open my $fh, '>>', $channel_file or die "Can't write to $channel_file: $!\n";
  flock $fh, LOCK_EX or die "Can't lock $channel_file: $!";
  seek($fh, 0, SEEK_END) or die "Couldn't seek in $channel_file: $!";
  print $fh "0 ", CSplat::Xlog::xlog_str($g);
  close $fh;
  $self->spawn_channel($channel);
}

sub spawn_channel {
  my ($self, $channel) = @_;
  unless ($CHANNEL_MAP{$channel}) {
    print "Launching new FooTV process for channel: $channel\n";
    my $pid = $self->{channel_launcher}(
      $channel,
      CSplat::Channel::channel_req_file($channel));
    print "Mapping channel $channel to $pid\n";
    $CHANNEL_MAP{$channel} = $pid;
  }
}

sub reap_child {
  my ($self, $pid) = @_;
  print "Reap child: $pid\n";
  my %pid_map;
  @pid_map{values %CHANNEL_MAP} = keys %CHANNEL_MAP;
  if (my $channel = $pid_map{$pid}) {
    print "Deleting one-off channel $channel for pid $pid\n";
    delete $CHANNEL_MAP{$channel};
  }
}

sub reaper {
  my $self = shift;
  sub {
    local ($!, $?);
    my $pid = waitpid(-1, WNOHANG);
    if ($pid != -1) {
      $self->reap_child($pid);
    }
  }
}

1
