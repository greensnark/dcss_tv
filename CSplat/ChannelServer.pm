use strict;
use warnings;

package CSplat::ChannelServer;

use lib '..';

use URI::Escape;
use LWP::Simple;

my $CHANNEL_SERVER = $ENV{CHANNEL_SERVER} || 'localhost';
my $CHANNEL_SERVER_PORT = $ENV{CHANNEL_SERVER_PORT} || 29880;

sub channel_query_url {
  "http://$CHANNEL_SERVER:$CHANNEL_SERVER_PORT/tv/channels"
}

sub canonicalize_query {
  my $query = shift;
  $query =~ s/^\s+|\s+$//g;
  $query =~ s/^!tv /!lg /i;
  $query
}

sub game_query_url {
  my $query = shift;
  ("http://$CHANNEL_SERVER:$CHANNEL_SERVER_PORT/search?query=" .
   uri_escape($query))
}

sub query_channels {
  my %channels;
  my $channel_listing = get(channel_query_url());
  return undef unless defined $channel_listing;
  if ($channel_listing) {
    for my $line (split /\n/, $channel_listing) {
      if ($line =~ /^(\S+) (.*)/) {
        $channels{$1} = $2;
      }
    }
  }
  \%channels
}

sub query_game {
  my $query = canonicalize_query(shift);

  my $tries = 5;

  while ($tries-- > 0) {
    my $result = get(game_query_url($query));
    return undef unless $result;

    $result =~ s/^\s+|\s+$//g;
    unless ($result =~ /^(\S+)[.] (.*)/) {
      print "Result $result was not in the [X]. [Y] form\n";
      return undef;
    }

    print "Got result for $query: $result\n";
    my ($key, $payload) = ($1, $2);
    my $weight = 1;
    if ($key =~ m{^(?:\d+/)?(\d+)$}) {
      $weight = $1;
    }

    if ($payload !~ /^:.*:$/) {
      if (canonicalize_query($payload) =~ /^!(?:lg|lm)/) {
        my $lookup = query_game($payload);
        return { weight => $weight, game => $lookup->{game} } if $lookup;
      }
      print "No game found for $query, retrying...\n";
      sleep 1;
      next;
    }

    $payload =~ s/^:|:$//g;
    return { weight => $weight, game => $payload };
  }
  undef
}

1
