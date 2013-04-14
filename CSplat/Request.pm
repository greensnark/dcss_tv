use strict;
use warnings;

package CSplat::Request;

use base 'Exporter';

our @EXPORT_OK;

use IO::Socket::INET;
use Carp;

use lib '..';
use CSplat::Xlog qw/xlog_hash/;
use Fcntl qw/LOCK_EX SEEK_CUR/;

sub new {
  my $class = shift;

  my $self = { @_ };
  $self->{host} ||= 'crawl.akrasiac.org';
  $self->{port} ||= 21976;
  bless $self, $class;
  $self
}

sub delete_file_queue {
  my $self = shift;
  $self->disconnect();
  my $file = $self->file_queue();
  unlink $file;
}

sub file_queue {
  shift()->{file_queue}
}

sub connect {
  my $self = shift;

  return if $self->{SOCK} || $self->{FH};
  if ($self->file_queue()) {
    open my $fh, '<', $self->file_queue()
      or die "No file queue: " . $self->file_queue();
    $self->{FH} = $fh;
    return;
  }
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

sub disconnect {
  my $self = shift;
  delete $self->{SOCK};
  delete $self->{FH};
}

sub handle {
  my $self = shift;
  if ($self->{FH}) {
    my $fh = $self->{FH};
    seek($fh, 0, 1);
    return $fh;
  }
  $self->{SOCK} || $self->{FH}
}

sub next_request_line {
  my $self = shift;

  while (1) {
    $self->connect();

    my $SOCK = $self->handle();
    my $line = <$SOCK>;

    if (!defined($line)) {
      return undef if $self->file_queue();
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
    return undef unless $line;
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
