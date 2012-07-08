package TV::ChannelQuery;

use strict;
use warnings;

use CSplat::ChannelServer;

sub new {
  my ($class, $channel_def) = @_;
  my $self = bless({ def => $channel_def }, $class);
  $self->_initialize();
  $self
}

sub _initialize {
  my $self = shift;
  $self->{queries} = [ map({ weight => 100000,  query => $_ },
                           split(/;;/, $self->{def})) ];
  for (@{$self->{queries}}) {
    for ($_->{query}) {
      s/^\s+|\s+$//;
    }
  }
}

sub next_game {
  my $self = shift;

  my $query = $self->_pick_query();
  $self->_query($query)
}

sub _total_query_weight {
  my $self = shift;
  my $weight = 0;
  $weight += $_->{weight} for @{$self->{queries}};
  $weight
}

sub _pick_query {
  my $self = shift;
  my $total_weight = $self->_total_query_weight();
  my $roll = int(rand($total_weight));
  for (@{$self->{queries}}) {
    if ($roll < $_->{weight}) {
      return $_->{query};
    }
    $roll -= $_->{weight};
  }
}

sub _update_weight {
  my ($self, $query, $weight) = @_;
  if ($weight && $weight > 0) {
    for (@{$self->{queries}}) {
      if ($_->{query} eq $query) {
        $_->{weight} = $weight;
      }
    }
  }
}

sub _query {
  my ($self, $query) = @_;
  my $result = CSplat::ChannelServer::query_game($query);
  if ($result) {
    $self->_update_weight($query, $result->{weight});
    return $result->{game};
  }
  undef
}

1
