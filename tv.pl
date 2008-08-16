#!/usr/bin/perl
use strict;
use warnings;
use IO::Socket::INET;

# TermCastTV version 1.2 by Eidolos

# changelog 1.1 - added "shuffle" as a "sort" method, reworked the others
#                 added a bunch of comments, some minor bug fixes
#           1.2 - now displays to viewers the prev/next ttyrecs between ttyrecs
#                 some internals changed now to accommodate this

# BEGIN CONFIG #################################################################
my $server      = '213.184.131.118'; # termcast server (probably don't change)
my $port        = 31337;             # termcast port (probably don't change)
my $ttyrec_dir  = '.';               # dir to look in for ttyrecs if no args
my $name        = 'C-SPLAT';         # name to use on termcast
my $pass        = 'd&8iMn3dhg^%';    # pass to use on termcast
my $thres       = 3;                 # maximum sleep secs on a ttyrec frame

# Leave only one of the following uncommented. shuffle should only be used if
# each ttyrec is independent (so if you have a game split across multiple
# ttyrecs, shuffle is probably a bad idea)

my $sort_method = \&lexicographic;
#my $sort_method = \&first_frame_timestamp;
#my $sort_method = \&mtime;
#my $sort_method = \&shuffle;

# END CONFIG ###################################################################

# Read one frame of the ttyrec filehandle passed to it
# If all goes according to plan, returns ($data, $timestamp)
# If we're at the end of the ttyrec, returns ('')
# If an error occurs (such as a short read), returns (undef)
sub read_frame
{
  my $handle = shift;
  my $hdr;
  my $data;

  my $hgot = read $handle, $hdr, 12;
  return '' if $hgot == 0;
  return undef if $hgot != 12;

  my @hdr = unpack "VVV", $hdr;
  my $timestamp = $hdr[0] + ($hdr[1] / 1_000_000);
  my $len = $hdr[2];

  my $dgot = read $handle, $data, $len;
  return undef if $dgot != $len;

  return ($data, $timestamp);
}

# Returns a list (sorted by $sort_method) of the ttyrecs in the given directory
# Note that the directory is given by name, not by handle
sub ttyrecs_in_dir
{
  my $dir = shift;
  my @ttyrecs;
  opendir(DIR, $dir) or return;

  @ttyrecs = map { ["$dir/$_", $_] }
             grep { /\.ttyrec$/ }
             readdir(DIR);
  @ttyrecs = $sort_method->(@ttyrecs);
  clear_cache();

  closedir(DIR);
  return @ttyrecs;
}

# Reconnect (or connect) to the termcast server and do the handshake.
# Returns () if an error occurred (such as not being able to connect)
# Otherwise returns the socket, which is ready to accept ttyrec frame data.
sub reconnect
{
  my ($server, $port, $name, $pass) = @_;
  my $sock = IO::Socket::INET->new(PeerAddr => $server,
                                   PeerPort => $port,
                                   Proto    => 'tcp',
                                   Blocking => 0,
                                   Timeout  => 10);
  return unless defined($sock);

  # Try to send the handshake
  defined(send($sock, "hello $name $pass\n", 0)) or return;

  print "We seem to have connected okay.\n";

  return $sock;
}

my @ttyrecs;
my $prev_ttyrec;
my $ttyrec;
my $ttyrec_handle;
my $sock;
my $prev_time = 0;
my $watchers = 0;
my $most_watchers = 0;

# Now the fun begins!

FRAME: while (1)
{
  # Did we run out of ttyrecs? (or, is this the first time we're in the loop?)
  if (@ttyrecs == 0)
  {
    # Use any directories given on the command line
    if (@ARGV)
    {
      for my $dir (@ARGV)
      {
        my @new = ttyrecs_in_dir($dir);
        if (@new == 0)
        {
          warn "Couldn't find any ttyrecs in $dir.\n";
        }
        else
        {
          push @ttyrecs, @new;
        }
      }
    }
    else
    {
      # Use the old standby..
      @ttyrecs = ttyrecs_in_dir($ttyrec_dir);
    }

    die "Couldn't find any ttyrecs!\n" if @ttyrecs == 0;
    print "Found " . scalar(@ttyrecs) . " ttyrec".(@ttyrecs==1?"":"s").".\n";
  }

  # Did we lose connection? (or, is this the first time we're in the loop?)
  if (!defined($sock))
  {
    print "Connecting to $server:$port...\n";
    $sock = reconnect($server, $port, $name, $pass);
    if (!defined($sock))
    {
      print "Unable to connect! Trying again in 10s...\n";
      sleep 10;
      next FRAME;
    }
    undef $ttyrec; # We're probably screwed up, so might as well start afresh
  }

  # Try reading output from the server (nonblocking)
  my $sock_out = <$sock>;
  if (defined($sock_out))
  {
    chomp $sock_out;
    if ($sock_out eq 'msg watcher connected')
    {
      ++$watchers;
      print "New watcher! Up to $watchers.";
      if ($watchers > $most_watchers)
      {
        $most_watchers = $watchers;
        print " That's a new record since this session has started!";
      }
      print "\n";
    }
    elsif ($sock_out eq 'msg watcher disconnected')
    {
      --$watchers;
      print "Lost a watcher. Down to $watchers.\n";
    }
    else # Don't know how to handle it, so just echo
    {
      print ">> $sock_out\n";
    }
  }

  # Did we finish the ttyrec? (or, is this the first time we're in the loop?)
  if (!defined($ttyrec))
  {
    $ttyrec = shift @ttyrecs;
    print "Using $ttyrec->[0].\n";

    # Let our people know what they're watching!
    print {$sock} "\e[2J\e[H";
    print {$sock} "That was \e[1;33m$prev_ttyrec.\e[0m\e[2;0H" if defined($prev_ttyrec);
    print {$sock} "Now playing \e[1;33m$ttyrec->[1]\e[0m.";
    sleep 5;
    print {$sock} "\e[2J\e[H";

    $prev_ttyrec = $ttyrec->[1];
    $ttyrec = $ttyrec->[0];

    open($ttyrec_handle, '<', $ttyrec) or do
    {
      warn "Unable to open $ttyrec; skipping.\n";
      undef $ttyrec;
      next FRAME;
    };
  }

  # Now we try to read a frame...
  my ($data, $time) = read_frame($ttyrec_handle);
  if (!defined($data) || ($data eq '' && !defined($time)))
  {
    if (!defined($data))
    {
      print "An error occurred in reading from $ttyrec. Waiting 2s and skipping to the next one..\n";
    }
    else
    {
      print "We seem to be done with $ttyrec. Waiting 2s..\n";
    }
    close $ttyrec_handle;
    undef $ttyrec;
    sleep 2;

    defined (send($sock, "\e[2J", 0)) or do
    {
      warn "Disconnected from server.\n";
      undef $sock;
    };

    next FRAME;
  }

  # find out how much time we need to wait and do so
  my $diff = $time - $prev_time;
  $diff = $thres if $diff > $thres;
  $diff = 0 if $prev_time == 0;
  $prev_time = $time;
  select undef, undef, undef, $diff;

  # ship off our frame!
  defined (send($sock, $data, 0)) or do
  {
    warn "Disconnected from server.\n";
    undef $sock;
  };
}

# sort methods

sub lexicographic
{
  return sort
  {
    $a->[1] cmp $b->[1]
  } @_;
}

sub shuffle
{
  my $i = @_;
  return unless $i;

  while (--$i)
  {
    my $j = int rand(1 + $i);
    @_[$i, $j] = @_[$j, $i];
  }

  return @_;
}

my %cache;

sub clear_cache
{
  %cache = ();
}

sub mtime
{
  return sort
  {
    ($cache{$a} ||= (stat $a->[0])[9])
    <=>
    ($cache{$b} ||= (stat $b->[0])[9])
  } @_
}

# Auxiliary function for sort method first_frame_timestamp
# Returns -1 if an error occurred, otherwise its first frame timestamp
sub get_first_frame_timestamp
{
  my $file = shift;

  open(my $handle, '<', $file) or do
  {
    warn "Unable to open $file: $!";
    return -1
  };

  my ($data, $timestamp) = read_frame($handle);
  close $handle;
  $timestamp = -1 unless defined $timestamp;
  return $timestamp;
}

sub first_frame_timestamp
{
  return
  grep { $_ != -1 } # Skip files we couldn't open
  sort
  {
    ($cache{$a->[0]} ||= get_first_frame_timestamp($a))
    <=>
    ($cache{$b->[0]} ||= get_first_frame_timestamp($b))
  } @_
}
