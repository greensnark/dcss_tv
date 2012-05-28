use strict;
use warnings;

package CSplat::Fetch;

use lib '..';
use base 'Exporter';

our @EXPORT_OK = qw/fetch_url/;

sub fetch_url {
  my ($url, $file) = @_;
  $file ||= url_file($url);
  my $command = "wget -q -c -O $file $url";
  my $status = system($command);
  my $err = '';
  $err = " ($!)" if $status == -1;
  die "Error fetching $url: $status$err\n" if ($status >> 8);
}

1
