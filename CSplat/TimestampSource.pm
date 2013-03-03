package CSplat::TimestampSource;

use strict;
use warnings;

use CSplat::Template;
use CSplat::Xlog;

sub new {
  my ($cls, $morgue_urls) = @_;
  bless {
    _urls => $morgue_urls
  }, $cls
}

sub resolve {
  my ($self, $g) = @_;
  $self->{urls} = [map($self->resolve_url($_, $g), @{$self->{_urls}})];
  $self
}

sub fetch_timestamp_file {
  my ($self, $filename, $dst) = @_;
  for my $url (@{$self->{urls}}) {
    print "Trying timestamp path $url/$filename\n";
    eval {
      CSplat::Fetch::fetch_url("$url/$filename", $dst);
    };
    return unless $@;
    warn "Error fetching timestamp file from $url/$filename: $@\n";
  }
  die "Could not fetch timestamp file $filename\n";
}

sub resolve_url {
  my ($self, $urlcfg, $g) = @_;
  CSplat::Template::resolve_template($urlcfg, $g)
}

1
