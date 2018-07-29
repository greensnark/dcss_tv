use strict;
use warnings;

package CSplat::Fetch;

use lib '..';
use base 'Exporter';

use Fcntl qw/LOCK_EX/;

our @EXPORT_OK = qw/fetch_url/;

sub fetch_url {
  my ($url, $file, $rate_limit) = @_;

  my $lock = "$file.lock";

  print "Trying to lock $lock\n";
  open my $lock_handle, '>', $lock or die "Can't open $lock: $!\n";
  flock $lock_handle, LOCK_EX or die "Can't lock $lock: $!\n";

  $file ||= url_file($url);

  my $rate_limit_flag = $rate_limit ? "--limit-rate=$rate_limit" : '';

  my $command = "wget -q -c $rate_limit_flag -O \Q$file\E \Q$url";
  print "$command\n";

  local $SIG{CHLD};
  my $status = system($command);
  my $err = '';
  $err = " ($!)" if $status == -1;

  close $lock_handle;
  unlink $lock;

  die "Error fetching $url: $status$err\n" if ($status >> 8);
}

1
