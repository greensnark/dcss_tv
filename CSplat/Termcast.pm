use strict;
use warnings;

package CSplat::Termcast;

use base 'Exporter';
use lib '..';

our @EXPORT_OK;

use CSplat::Ttyrec qw/tv_frame_strip ttyrec_path/;
use CSplat::Seek qw/tty_frame_offset/;
use CSplat::Xlog qw/desc_game desc_game_brief/;
use IO::Handle;
use IO::Socket::INET;
use Carp;
use Fcntl qw/SEEK_SET/;
use Data::Dumper;

my $TERMCAST_HOST = $ENV{TERMCAST_HOST} || 'termcast.develz.org';

sub read_password {
  my $pwfile = shift;
  open my $inf, '<', $pwfile or die "Can't read $pwfile: $!\n";
  chomp(my $text = <$inf>);
  die "No password for termcast login?\n" unless $text;
  $text
}

sub new {
  my ($class, @misc) = @_;
  my $self = { @misc };

  $self->{host} ||= $TERMCAST_HOST;
  $self->{port} ||= 31337;

  unless ($self->{local}) {
    $self->{pass} = read_password($self->{passfile}) if $self->{passfile};
    carp("Need channel name (name) and password (pass)\n")
      unless $self->{name} && $self->{pass};
  }

  bless $self, $class;
  $self
}

sub callback {
  my ($self, $callback) = @_;
  push @{$self->{_callbacks}}, $callback;
}

sub clear {
  my $self = shift;
  $self->connect();
  $self->write("\e[2J\ec");
}

sub reset {
  my $self = shift;
  $self->connect();
  $self->write("\ec");
}

sub connect {
  my $self = shift;
  return if defined($self->{SOCK});

  if ($self->{local}) {
    $self->{SOCK} = \*STDOUT;
    $self->{SOCK}->autoflush;
  }

  while (!defined($self->{SOCK})) {
    $self->reconnect();
    last if defined($self->{SOCK});
    print "Unable to connect to $self->{host}:$self->{port}, ",
      "retrying in 10s...\n";
    sleep 10;
  }
}

sub reconnect {
  my $self = shift;
  return if defined($self->{SOCK});

  print "Attempting to connect...\n";

  my $server = $self->{host};
  my $port = $self->{port};
  my $SOCK = IO::Socket::INET->new(PeerAddr => "$server:$port",
                                   Proto    => 'tcp',
                                   Type => SOCK_STREAM);
  warn "Unable to connect: $!\n" unless defined $SOCK;
  return unless defined($SOCK);

  print "Sending handshake to server for $self->{name}...\n";
  # Try to send the handshake
  print $SOCK "hello $self->{name} $self->{pass}\n";

  my $response = <$SOCK>;
  unless ($response and $response =~ /^hello, $self->{name}\s*$/) {
    warn "Bad response from server: $response ($!)\n";
    undef $SOCK;
  }
  else {
    print "Connected!\n";
    $self->{SOCK} = $SOCK;
  }
}

sub write {
  my $self = shift;
  $self->connect();
  my $SOCK = $self->{SOCK};
  for my $text (@_) {
    print $SOCK $text;
  }
}

sub disconnect {
  my $self = shift;
  delete $self->{SOCK};
}

sub is_death_frame {
  my $frame = shift;
  $frame =~ /You die\.\.\./;
}

sub min {
  my ($a, $b) = @_;
  $a > $b ? $a : $b
}

sub frame_delay_provider {
  my $g = shift;
  my $idle_clamp = $$g{idle_clamp} || 4;
  my $speed_up = $$g{playback_speed} || 1;
  $speed_up = 10 if $speed_up > 10;
  $speed_up = 0.1 if $speed_up < 0.1;
  return sub {
    my $wait = shift;
    $wait /= $speed_up;
    $wait = $idle_clamp if $wait > $idle_clamp;
    $wait
  };
}

sub play_ttyrec {
  my ($self, $g, $ttyfile, $offset, $stop_offset, $frame) = @_;

  $self->write($frame) if $frame;
  warn "Playing ttyrec for ", desc_game($g), " from $ttyfile\n";

  my $frame_delay = frame_delay_provider($g);
  my $t = Term::TtyRec::Plus->new(infile => $ttyfile,
                                  time_threshold => 3);
  seek($t->filehandle(), $offset, SEEK_SET) if $offset;

  my $cancelled = 0;

 PLAYBACK:
  while (my $fref = $t->next_frame()) {
    my $delay = $frame_delay->($fref->{diff});
    if ($delay > 0) {
      select undef, undef, undef, $delay;
    }
    $self->write(tv_frame_strip($fref->{data}));
    select undef, undef, undef, 1 if is_death_frame($fref->{data});

    if ($self->{_callbacks}) {
      for my $cb (@{$self->{_callbacks}}) {
        my $res = $cb->($g);
        if (($res || '') eq 'stop') {
          print "Callback requested end of playback, obliging.\n";
          $cancelled = 1;
          last PLAYBACK;
        }
      }
    }
    if ($stop_offset && tell($t->filehandle()) >= $stop_offset) {
      print "Stop offset $stop_offset reached, stopping\n";
      last;
    }
  }
  print "Done playback.\n";
  close($t->filehandle());
  $cancelled
}

sub play_game {
  my ($self, $g) = @_;

  my $playback_range =
    eval {
      tty_frame_offset($g)
    };

  warn $@ if $@;

  if ($@) {
    $self->clear();
    $self->write("Ttyrec appears corrupted.\r\n");
  }

  if (!$playback_range) {
    $self->write("Could not find playback range, aborting.\r\n");
    return;
  }

  $self->clear();
  $self->reset();

  my $skipping = 1;
  for my $ttyrec (split / /, $g->{ttyrecs}) {
    my $start_file = $playback_range->start_file() eq $ttyrec;
    my $end_file = $playback_range->end_file() eq $ttyrec;

    if ($skipping) {
      next if !$start_file;
      undef $skipping;
    }

    my $offset = 0;
    my $stop_offset;
    my $frame;

    if ($start_file) {
      $offset = $playback_range->start_offset();
      $frame = $playback_range->frame();
    }

    if ($end_file) {
      $stop_offset = $playback_range->end_offset();
    }

    my $cancelled = eval {
      $self->play_ttyrec($g, ttyrec_path($g, $ttyrec), $offset,
                         $stop_offset, $frame);
    };
    warn "$@\n" if $@;

    last if $end_file || $cancelled;
  }
}

1
