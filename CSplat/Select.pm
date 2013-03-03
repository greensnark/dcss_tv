use strict;
use warnings;

package CSplat::Select;

use Date::Manip;
use CSplat::Xlog;

sub field_mangle {
  my ($field, $v) = @_;
  return $v unless defined $v;
  if ($field eq 'start' || $field eq 'end') {
    $v =~ s/[SD]$//;
  }
  $v
}

sub make_filter {
  my $filter = shift;
  if (ref($filter)) {
    # Make a copy so we don't mess with the original.
    $filter = { %$filter };
  } else {
    $filter = CSplat::Xlog::xlog_hash($filter);
  }

  my @keys = keys %$filter;

  my @goodkeys = qw/name start end god vmsg tmsg place ktyp title
                    xl char turn time/;
  my %good = map(($_ => 1), @goodkeys);

  for my $key (@keys) {
    delete @$filter{$key} unless $good{$key};
  }
  $filter
}

sub filter_matches {
  my ($filter, $g) = @_;
  for my $key (keys %$filter) {
    return if field_mangle($key, $$filter{$key}) ne
       field_mangle($key, ($$g{$key} || ''));
  }
  1
}

1
