package CSplat::TtyrecListParser;

use strict;
use warnings;
use Data::Dumper;

use URI::Escape qw//;

my %PARSE_EXPRESSIONS = (
  'crawl.develz.org' =>
       qr{<\s*a\s+href\s*=\s*["']([^"']*?[.]ttyrec(?:\.gz|\.bz2|\.xz)?)["'].*?
          (\d+(?:\.\d+)?[kMB]|\s\d+)\s*$}xim,
                         ,
  'default' => qr{<\s*a\s+href\s*=\s*["']([^"']*?[.]ttyrec(?:\.gz|\.bz2|\.xz)?)["']}is
);

sub new {
  bless({ }, shift)
}

sub hostname {
  my $url = shift;
  if ($url =~ m{https?://([^/]*)}) {
    return $1;
  }
  $url
}

sub listing_parse_expression {
  my ($self, $host) = @_;
  $PARSE_EXPRESSIONS{$host} || $PARSE_EXPRESSIONS{default}
}

sub human_readable_size {
  my $size = shift;
  s/^\s+//, s/\s+$// for $size;
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
  return URI::Escape::uri_unescape($1) if $url =~ /(\d{4}-\d{2}.*)/;
  return $url;
}

sub parse {
  my ($self, $server_url, $listing) = @_;

  my $hostname = hostname($server_url);
  my $listing_parse_expression = $self->listing_parse_expression($hostname);
  print("Parsing listing from $hostname using $listing_parse_expression\n");
  my (@urlsizes) = $listing =~ /$listing_parse_expression/g;
  my @urls;
  for (my $i = 0; $i < @urlsizes; ++$i) {
    my $url = $urlsizes[$i];
    push @urls, { u => $url,
                  timestr => ttyrec_url_timestring($url) };
  }
  grep($_->{u} =~ /\.ttyrec/, @urls)
}

1
