use strict;
use warnings;

package CSplat::TtyrecList;

use base 'Exporter';
use LWP::Simple qw//;
use IO::Socket::INET;
use CSplat::Config;
use CSplat::TtyrecListParser;

our @EXPORT_OK = qw/fetch_listing/;

sub fetch_listing {
  my ($nick, $server_url) = @_;
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

sub http_fetch {
  my ($nick, $server_url) = @_;
  $server_url = "$server_url/" unless $server_url =~ m{/$};
  print "HTTP GET $server_url\n";
  my $listing = LWP::Simple::get($server_url) or do {
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
