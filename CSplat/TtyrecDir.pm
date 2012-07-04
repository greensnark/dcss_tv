use strict;
use warnings;

package CSplat::TtyrecDir;

use lib '..';

use CSplat::Util qw/with_lock_do/;

use Fcntl qw/LOCK_EX LOCK_SH/;

sub lock_file {
  my ($cls, $dir) = @_;
  "$dir/ttyrec.lock"
}

sub lock {
  my ($cls, $dir, $lock_mode, $timeout, $action) = @_;
  my $lock_file = $cls->lock_file($dir);
  with_lock_do($lock_file, $lock_mode,
               "could not lock $dir", $timeout, $action)
}

sub lock_for_read {
  my ($cls, $dir, $action) = @_;
  $cls->lock($dir, LOCK_SH, 0, $action)
}

sub lock_for_download {
  my ($cls, $dir, $action) = @_;
  $cls->lock($dir, LOCK_SH, 0,
             sub {
               $cls->write_timestamp($dir);
               $action->()
             })
}

sub lock_for_vacuum {
  my ($cls, $dir, $timeout, $action) = @_;
  $cls->lock($dir, LOCK_EX, $timeout, $action)
}

sub timestamp_file {
  my ($cls, $dir) = @_;
  "$dir/fetch.timestamp"
}

sub write_timestamp {
  my ($cls, $dir) = @_;
  my $ts_file = $cls->timestamp_file($dir);
  open my $outf, '>', $ts_file or die "Can't write $ts_file: $!\n";
  close $outf;
}

sub new {
  my ($class, $dir) = @_;
  bless({ dir => $dir }, $class)
}

sub each_player_directory {
  my ($self, $action) = @_;

  my @server_dirs = glob("$self->{dir}/*");
  for my $server_dir (@server_dirs) {
    $self->each_server_player_directory($server_dir, $action);
  }
}

sub each_server_player_directory {
  my ($self, $dirname, $action) = @_;
  opendir my $dir, $dirname or die "Can't read $dirname: $!\n";
  while (my $player = readdir($dir)) {
    next if $player =~ /^\./;

    my $player_dir = "$dirname/$player";
    next unless -d $player_dir;
    $action->($player_dir);
  }
}

1
