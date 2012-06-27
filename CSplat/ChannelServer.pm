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
  my $query = shift;
  get(game_query_url($query))
}

1
