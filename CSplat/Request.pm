use strict;
use warnings;

package CSplat::Request;

use base 'Exporter';

our @EXPORT_OK;

use IO::Socket::INET;
use Carp;

use CSplat::Xlog qw/xlog_hash/;

sub new {
  my $class = shift;

  my $self = { @_ };
  $self->{host} ||= 'crawl.akrasiac.org';
  $self->{port} ||= 21976;
  bless $self, $class;
  $self
}

sub connect {
  my $self = shift;

  return if $self->{SOCK};
  while (!$self->{SOCK}) {
    $self->{SOCK} =
      IO::Socket::INET->new(PeerAddr => $self->{host},
                            PeerPort => $self->{port},
                            Type => SOCK_STREAM,
                            Timeout => 30);
    unless ($self->{SOCK}) {
      sleep 3;
    }
  }
}

sub next_request_line {
  my $self = shift;

  while (1) {
    $self->connect();
    my $SOCK = $self->{SOCK};

    my $line = <$SOCK>;

    if (!defined($line)) {
      # Lost our connection...
      delete $self->{SOCK};
      next;
    }

    next unless $line && $line =~ /\S/;
    chomp $line;

    return $line;
  }
}

sub next_request {
  my $self = shift;
  while (1) {
    my $line;
    eval {
      $line = $self->next_request_line();
    };
    warn "$@" if $@;
    if ($line =~ /^\d+ (.*)/) {
      my $g = xlog_hash($1);
      # The id here will be Henzell's game id, which is sharply distinct
      # from our own game id, so toss it.
      delete $$g{id};
      return $g
    }
  }
}

1
