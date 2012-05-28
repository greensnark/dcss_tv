# Defines the playback range in a stream of ttyrecs. The ttyrecs must
# be in chronological order. The start_offset is the offset in the
# start_ttyrec, and the end_offset is the offset to stop at in the
# end_ttyrec.

use strict;
use warnings;

package CSplat::TtyPlayRange;

sub new {
  my $self = { };
  bless $self, shift();
  $self->initialize(@_);
  $self
}

sub initialize {
  my $self = shift;
  my %options = @_;
  $self->{start_file} = $options{start_file};
  $self->{start_offset} = $options{start_offset};
  $self->{end_file} = $options{end_file};
  $self->{end_offset} = $options{end_offset};
  $self->{frame} = $options{frame};
}

sub frame {
  my $self = shift;
  $self->{frame}
}

sub start_file {
  my $self = shift;
  $self->{start_file}
}

sub start_offset {
  my $self = shift;
  $self->{start_offset}
}

sub end_file {
  my $self = shift;
  $self->{end_file}
}

sub end_offset {
  my $self = shift;
  $self->{end_offset}
}

1
