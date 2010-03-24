use strict;
use warnings;

package CSplat::TtyrecList;

use base 'Exporter';
use LWP::Simple;
use IO::Socket::INET;

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

  if (!$HTTP_FETCH{$server}) {
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
    push @ttyrecs, { u => $list[$i], sz => $list[$i + 1] };
  }
  print "Cleaning up urls with base $url\n";
  clean_ttyrec_url($url, $_) for @ttyrecs;
  @ttyrecs = sort_ttyrecs(\@ttyrecs);
  print "Done fetching direct listing for $nick\n";
  \@ttyrecs
}

sub clean_ttyrec_url {
  my ($baseurl, $url) = @_;
  $url->{u} =~ s{^./}{};
  $baseurl = "$baseurl/" unless $baseurl =~ m{/$};
  $url->{u} = $baseurl . $url->{u};
  $url
}

sub human_readable_size {
  my $size = shift;
  my ($suffix) = $size =~ /([KMG])$/i;
  $size =~ s/[KMG]$//i;
  if ($suffix) {
    $suffix = lc($suffix);
    $size *= 1024 if $suffix eq 'k';
    $size *= 1024 * 1024 if $suffix eq 'm';
    $size *= 1024 * 1024 * 1024 if $suffix eq 'g';
  }
  $size
}

sub ttyrec_url_timestring {
  my $url = shift;
  return $1 if $url =~ /(\d{4}-\d{2}.*)/;
  return $url;
}

sub http_fetch {
  my ($nick, $server_url) = @_;
  $server_url = "$server_url/" unless $server_url =~ m{/$};
  print "HTTP GET $server_url\n";
  my $listing = get($server_url) or do {
    print "Could not fetch listing from $server_url\n";
    return;
  };
  my @urlsizes = $listing =~ /a\s+href\s*=\s*["'](.*?)["'].*?([\d.]+[kM])\b/gi;
  my @urls;
  for (my $i = 0; $i < @urlsizes; $i += 2) {
    my $url = $urlsizes[$i];
    my $size = human_readable_size($urlsizes[$i + 1]);
    push @urls, { u => $url,
                  timestr => ttyrec_url_timestring($url),
                  sz => $size };
  }
  my @ttyrecs = map(clean_ttyrec_url($server_url, $_),
                    grep($_->{u} =~ /\.ttyrec/, @urls));
  @ttyrecs = sort_ttyrecs(\@ttyrecs);
  \@ttyrecs
}

1
