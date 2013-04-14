use strict;
use warnings;

package CSplat::ChannelMonitor;

use lib '..';

use File::Path;
use File::Spec;
use CSplat::ChannelServer;
use CSplat::Channel;

my $CHANNEL_DEF_DIR = $CSplat::Channel::CHANNEL_DEF_DIR;

sub new {
  my $self = bless({}, shift());
  my $channel_launcher = shift;
  $self->{channel_launcher} = $channel_launcher;
  $self->{channel_map} = { };
  $self
}

sub run {
  my $self = shift;
  while (1) {
    $self->update_channels();
    sleep 5;
  }
}

sub query_channels {
  CSplat::ChannelServer::query_channels()
}

sub channel_filename {
  my ($self, $channel_name) = @_;
  CSplat::Channel::channel_def_file($channel_name)
}

sub write_channel_file {
  my ($self, $channel, $channel_def) = @_;
  CSplat::Channel::create_channel_directory();

  my $channel_file = $self->channel_filename($channel);
  open my $outf, '>', $channel_file or die "Could not open $channel_file for write: $!\n";
  print $outf $channel_def;
  close $outf;
}

sub delete_channel_file {
  my ($self, $channel) = @_;
  my $channel_file = $self->channel_filename($channel);
  unlink $channel_file if -f $channel_file;
  $channel_file
}

sub delete_channel {
  my ($self, $channel) = @_;
  $self->delete_channel_file($channel);
  delete $self->{channel_map}{$channel}
}

sub valid_channel_name {
  my ($self, $channel) = @_;
  CSplat::Channel::valid_channel_name($channel)
}

sub launch_channel {
  my ($self, $channel, $channel_def) = @_;
  unless ($self->{channel_map}{$channel}) {
    print "Launching new FooTV process for $channel: $channel_def\n";
    my $pid = $self->{channel_launcher}($channel);
    $self->{channel_map}{$channel} = $pid;
  }
}

sub update_channels {
  my $self = shift;
  my $channels = $self->query_channels;
  # Ignore temporary failures to reach the channel def server.
  return unless defined $channels;

  for my $channel (keys %$channels) {
    next unless $self->valid_channel_name($channel);
    my $channel_def = $$channels{$channel};
    $self->write_channel_file($channel, $channel_def);
    $self->launch_channel($channel, $channel_def);
  }

  for my $old_channel (keys %{$self->{channel_map}}) {
    next if $$channels{$old_channel};
    $self->delete_channel($old_channel);
  }
}

1
