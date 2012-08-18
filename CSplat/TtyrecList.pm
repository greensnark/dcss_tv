use strict;
use warnings;

package CSplat::TtyrecList;

use base 'Exporter';
use LWP::Simple;
use IO::Socket::INET;
use CSplat::Config;
use CSplat::TtyrecListParser;

our @EXPORT_OK = qw/fetch_listing/;

our $DIRECTLIST_PORT = 21977;

my %HTTP_FETCH;

sub get_server {
  my $url = shift;
  my ($server) = $url =~ m{\w+://([^/]+)};
  $server
}

sub fetch_listing {
  my ($nick, $server_url) = @_;
  my $server = get_server($server_url);

  if (!$HTTP_FETCH{$server} && !CSplat::Config::http_fetch_only($server)) {
    my $rttyrec = direct_fetch($nick, $server, $server_url);
    return $rttyrec if $rttyrec;

    # We failed to do a direct fetch, only attempt http fetches in future.
    $HTTP_FETCH{$server} = 1;
  }

  my $res = http_fetch($nick, $server_url);
  $res
}

sub sort_ttyrecs {
  my $ref = shift;
  sort { $a->{timestr} cmp $b->{timestr} } @$ref
}

sub clean_ttyrec_url {
  my ($baseurl, $url) = @_;
  $url->{u} =~ s{^./}{};
  $baseurl = "$baseurl/" unless $baseurl =~ m{/$};
  $url->{u} = $baseurl . $url->{u};
  $url
}

sub direct_fetch {
  my ($nick, $hostname, $url) = @_;

  print "Attempting direct fetch from $hostname...\n";
  my $sock = IO::Socket::INET->new(PeerAddr => $hostname,
                                   PeerPort => $DIRECTLIST_PORT,
                                   Type => SOCK_STREAM,
                                   Timeout => 12);
  return undef unless $sock;

  print $sock "$nick\r\n";
  my $list = <$sock>;
  undef $sock;

  my @list = split ' ', $list;

  print "Found ", @list / 2, " ttyrecs for $nick on $hostname\n";
  my @ttyrecs;
  for (my $i = 0; $i < @list; $i += 2) {
    push @ttyrecs, { u => $list[$i],
                     timestr => $list[$i],
                     sz => $list[$i + 1] };
  }
  print "Cleaning up urls with base $url\n";
  clean_ttyrec_url($url, $_) for @ttyrecs;
  @ttyrecs = sort_ttyrecs(\@ttyrecs);
  print "Done fetching direct listing for $nick\n";
  \@ttyrecs
}

sub http_fetch {
  my ($nick, $server_url) = @_;
  $server_url = "$server_url/" unless $server_url =~ m{/$};
  print "HTTP GET $server_url\n";
  my $listing = get($server_url) or do {
    print "Could not fetch listing from $server_url\n";
    return;
  };
  print "Done fetching HTTP listing for $nick\n";
  my @urls = CSplat::TtyrecListParser->new()->parse($server_url, $listing);
  clean_ttyrec_url($server_url, $_) for @urls;
  my @ttyrecs = sort_ttyrecs(\@urls);
  print "Sorted HTTP listing for $nick, ", scalar(@ttyrecs), " files found\n";
  \@ttyrecs
}

1
