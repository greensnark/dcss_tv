use strict;
use warnings;

package CSplat::TurnSeek;

use lib '..';

use CSplat::GameTimestamp;
use CSplat::TtyTime qw/tty_time/;

sub new {
  my $self = bless({}, shift());
  $self->initialize(@_);
  return undef unless $self->start_turn() || $self->end_turn() || $self->{end_time};

  $self
}

sub game_seek_turn {
  my $turn = shift;
  if ($turn && $turn =~ /^t([+-]?\d+)$/i) {
    return $1;
  }
  undef
}

sub initialize {
  my ($self, $g) = @_;
  $$self{g} = $g;

  my $seekbefore = game_seek_turn($$g{seekbefore});
  my $seekafter = game_seek_turn($$g{seekafter});
  #return unless defined($seekbefore) || defined($seekafter);

  my $start = $self->resolve_turn($seekbefore);
  my $end = $self->resolve_turn($seekafter);
  $self->{start} = $start;
  $self->{end} = $end;

  $self->{start_time} = tty_time($g, 'start');
  # No defined end_time if this is not a milestone:
  $self->{end_time} = tty_time($g, 'time');

  # For milestones, if there is a defined end-time, make the start time the
  # milestone time.
  if ($end && $self->{end_time}) {
    $self->{milestone_start_time} = $self->{end_time};
  }
}

sub resolve_turn {
  my ($self, $turn) = @_;
  return undef unless defined $turn;
  if ($turn =~ /^[+-]/) {
    $turn += $$self{g}{turn};
    $turn = 0 if $turn < 0;
  }
  $turn
}

sub start_turn {
  my $self = shift;
  $self->{start}
}

sub end_turn {
  my $self = shift;
  my $end = $self->{end};
  $end ? $end + 99 : undef
}

sub default_start_time {
  my $self = shift;
  $$self{start_time}
}

sub default_end_time {
  my $self = shift;
  $$self{end_time}
}

sub timestamp {
  my $self = shift;
  $self->{timestamp} ||= CSplat::GameTimestamp->new($self->{g})
}

sub start_time {
  my $self = shift;
  my $start = $self->start_turn();
  $start && $self->timestamp()->timestamp_for_turn($start) ||
    $self->{milestone_start_time}
}

# Returns true if the start time is a hard start-here-dammit time.
sub hard_start_time {
  my $self = shift;
  defined($self->{start})
}

sub end_time {
  my $self = shift;
  my $end = $self->end_turn();
  ($end && $self->timestamp()->timestamp_for_turn($end)) ||
    $self->default_end_time()
}

1
