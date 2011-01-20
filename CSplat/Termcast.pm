use strict;
use warnings;

package CSplat::Termcast;

use base 'Exporter';

our @EXPORT_OK;

use CSplat::Ttyrec qw/tv_frame_strip ttyrec_path/;
use CSplat::Seek qw/tty_frame_offset/;
use CSplat::Xlog qw/desc_game desc_game_brief/;
use IO::Handle;
use IO::Socket::INET;
use Carp;
use Fcntl qw/SEEK_SET/;

my $TERMCAST_HOST = 'localhost';

sub read_password {
  my $pwfile = shift;
  chomp(my $text = do { local @ARGV = $pwfile; <> });
  die "No password for termcast login?\n" unless $text;
  $text
}

sub new {
  my ($class, @misc) = @_;
  my $self = { @misc };

  $self->{host} ||= $TERMCAST_HOST;
  $self->{port} ||= 31337;

  $self->{pass} = read_password($self->{passfile}) if $self->{passfile};

  carp("Need channel name (name) and password (pass)\n")
    unless $self->{name} && $self->{pass};

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

  print "Sending handshake to server...\n";
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

sub play_ttyrec {
  my ($self, $g, $ttyfile, $offset, $stop_offset, $frame) = @_;

  $self->write($frame) if $frame;

  warn "Playing ttyrec for ", desc_game($g), " from $ttyfile\n";

  my $t = Term::TtyRec::Plus->new(infile => $ttyfile,
                                  time_threshold => 3);
  seek($t->filehandle(), $offset, SEEK_SET) if $offset;

 PLAYBACK:
  while (my $fref = $t->next_frame()) {
    select undef, undef, undef, $fref->{diff};
    $self->write(tv_frame_strip($fref->{data}));
    select undef, undef, undef, 1 if is_death_frame($fref->{data});

    if ($self->{_callbacks}) {
      for my $cb (@{$self->{_callbacks}}) {
        my $res = $cb->($g);
        if (($res || '') eq 'stop') {
          print "Callback requested end of playback, obliging.\n";
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
}

sub play_game {
  my ($self, $g) = @_;

  my ($ttr, $offset, $stop_offset, $frame) =
    eval {
      tty_frame_offset($g)
    };

  warn $@ if $@;

  if ($@) {
    $self->clear();
    $self->write("Ttyrec appears corrupted.");
  }

  $stop_offset ||= 0;

  $self->clear();
  $self->reset();

  my $skipping = 1;
  for my $ttyrec (split / /, $g->{ttyrecs}) {
    if ($skipping) {
      next if $ttr ne $ttyrec;
      undef $skipping;
    }

    eval {
      $self->play_ttyrec($g, ttyrec_path($g, $ttyrec), $offset,
                         $stop_offset, $frame);
    };
    warn "$@\n" if $@;

    undef $offset;
    undef $stop_offset;
    undef $frame;
  }
}

1
