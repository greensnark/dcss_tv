package CSplat::TtyrecSourceDir;

use strict;
use warnings;

use CSplat::Template;
use CSplat::Notify;
use CSplat::TtyrecList;
use CSplat::TtyrecListParser;
use LWP::Simple qw//;

use threads;
use threads::shared;

my $CACHE_MAX = 25;
my %CACHED_TTYREC_URLS :shared;

sub clear_cached_urls {
  %CACHED_TTYREC_URLS = ();
}

sub new {
  my ($cls, $cfg) = @_;

  my $ttyrec_template = $cfg;
  my $listing_template;

  if (ref($cfg) eq 'HASH') {
    $ttyrec_template = $cfg->{ttyrec};
    $listing_template = $cfg->{listing};
  }

  bless {
    _cfg => $cfg,
    ttyrec_template => $ttyrec_template,
    listing_template => $listing_template
  }, $cls
}

sub ttyrec_template {
  shift()->{ttyrec_template}
}

sub listing_template {
  shift()->{listing_template}
}

sub resolve {
  my ($self, $g) = @_;
  $self->{ttyrec_url} =
    CSplat::Template::resolve_template($self->ttyrec_template(), $g);
  $self->{listing_url} =
    CSplat::Template::resolve_template($self->listing_template(), $g);
  $self
}

sub listing_url {
  shift()->{listing_url}
}

sub ttyrec_url {
  shift()->{ttyrec_url}
}

sub have_cached_listing {
  my ($self, $time_wanted) = @_;
  my $ttyrec_url = $self->ttyrec_url();
  my $cache = $CACHED_TTYREC_URLS{$ttyrec_url};
  return $cache && $cache->[0] >= $time_wanted;
}

sub clear_cached_listing {
  my $self = shift;
  delete $CACHED_TTYREC_URLS{$self->ttyrec_url()}
}

sub ttyrec_urls {
  my ($self, $listener, $g, $time_wanted) = @_;
  my $now = time();
  my $ttyrec_url = $self->ttyrec_url();
  my $listing_url = $self->listing_url();

  my $cache = $CACHED_TTYREC_URLS{$ttyrec_url};
  return @{$cache->[1]} if $cache && $cache->[0] >= $time_wanted;

  my $rttyrecs = $self->_list_ttyrecs($listener, $g, $ttyrec_url, $listing_url);
  $rttyrecs = [] unless defined $rttyrecs;

  if (length(keys %CACHED_TTYREC_URLS) > $CACHE_MAX) {
    %CACHED_TTYREC_URLS = ();
  }

  $CACHED_TTYREC_URLS{$ttyrec_url} = shared_clone([ $now, $rttyrecs ]);
  @$rttyrecs
}

sub _list_ttyrecs {
  my ($self, $listener, $g, $ttyrec_url, $listing_url) = @_;
  if ($listing_url) {
    $self->direct_list_ttyrecs($listener, $g, $listing_url)
  }
  else {
    $self->http_list_ttyrecs($listener, $g, $ttyrec_url)
  }
}

sub direct_list_ttyrecs {
  my ($self, $listener, $g, $listing_url) = @_;

  CSplat::Notify::notify($listener,
                        "Fetching ttyrec listing from " . $listing_url . "...");
  my $url_list = LWP::Simple::get($listing_url);
  my @urls = grep(/\.ttyrec/, split(/\n/, $url_list));
  my $ttyrec_base = $self->ttyrec_url();

  my @ttyrec_urls;
  for my $url (@urls) {
    $url =~ s/^\s+//;
    $url =~ s/\s+$//;
    push @ttyrec_urls, {
      u => "$ttyrec_base/$url",
      timestr => CSplat::TtyrecListParser::ttyrec_url_timestring($url)
    };
  }
  \@ttyrec_urls
}

sub http_list_ttyrecs {
  my ($self, $listener, $g, $ttyrec_url) = @_;
  CSplat::Notify::notify($listener,
                        "Fetching ttyrec listing from " . $ttyrec_url . "...");
  CSplat::TtyrecList::fetch_listing($$g{name}, $ttyrec_url);
}

1
