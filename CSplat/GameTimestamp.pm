use strict;
use warnings;

package CSplat::GameTimestamp;
use lib '..';

use CSplat::Config;
use CSplat::Fetch;
use CSplat::Xlog qw/desc_game_brief/;
use CSplat::TtyTime qw/tty_time/;
use File::Path;
use Date::Manip;

sub new {
  my $self = bless({}, shift());
  $self->initialize(@_);
  $self
}

sub initialize {
  my ($self, $g) = @_;

  $self->{g} = $g;
  $self->fetch_timestamp_file($g)
}

sub timestamp_file_offset {
  my ($turn, $filesize, $eof) = @_;
  if ($eof) {
    die "Timestamp file is too small" unless $filesize >= 8;
    return $filesize - $filesize % 4 - 4;
  }
  my $slab = int($turn / 100) - 1;
  4 + 4 * $slab
}

sub end_turn {
  my $self = shift;
  my $g = $self->{g};
  unless ($g->{milestone}) {
    return $g->{turn};
  }
  undef
}

sub find_timestamp_for_turn {
  my ($self, $turn) = @_;

  my $file = $self->{file};
  return '' unless defined $turn;

  my $end_turn = $self->end_turn();
  my $eof = $turn == -1;
  if ($end_turn && $turn > $end_turn) {
    $eof = 1;
  }

  if ($turn >= 0 && $turn < 100) {
    return tty_time($self->{g}, 'start');
  }

  open my $inf, '<', $file;
  binmode $inf;

  my $offset = timestamp_file_offset($turn, -s($file), $eof);
  print "Seeking to offset $offset in $file for turn $turn\n";
  seek($inf, $offset, 0) or
    die "Cannot find turn $turn in timestamp file $file\n";
  my $ts;
  read($inf, $ts, 4) ||
    die "Could not read timestamp for turn $turn from timestamp file $file\n";
  ParseDateString("epoch " . unpack('N', $ts))
}

sub timestamp_for_turn {
  my ($self, $turn) = @_;
  my $cached_ts = ($$self{ts} ||= { });
  unless ($cached_ts->{$turn}) {
    $cached_ts->{$turn} = $self->find_timestamp_for_turn($turn);
  }
  $cached_ts->{$turn}
}

sub timestamp_file_time {
  my $rawtime = shift;
  $rawtime =~ s{^(\d{4})(\d{2})(\d{2})(\d{2}\d{2}\d{2})[SD]?$}
               {$1 . sprintf("%02d", ($2 + 1)) . $3 . '-' . $4}e;
  $rawtime
}

sub timestamp_filename {
  my $g = shift;

  my $start = timestamp_file_time($$g{start});
  "timestamp-$$g{name}-$start.ts"
}

sub timestamp_paths {
  my $self = shift;
  my $g = $self->{g};
  my $timestamp_file = timestamp_filename($g);
  map(resolve_player_directory($_, $g) . "/$timestamp_file",
      CSplat::Config::game_server_list_field($g, 'timestamp_path'))
}

sub timestamp_local_file_path {
  my ($self, $url) = @_;
  my $g = $$self{g};
  my $server = CSplat::Config::game_server($g);

  my $dir = CSplat::Config::ttyrec_dir() . "/$server/$g->{name}/";
  mkpath( [ $dir ] ) unless -d $dir;
  $dir . timestamp_filename($g)
}

sub fetch_timestamp_file {
  my ($self, $g) = @_;
  $self->{file} = $self->timestamp_local_file_path();
  my $timestamp_file = timestamp_filename($g);
  print("Downloading timestamp file to $self->{file}\n");
  my $src = CSplat::Config::game_server_timestamp_source($g);
  $src->fetch_timestamp_file($timestamp_file, $self->{file});
}

1
