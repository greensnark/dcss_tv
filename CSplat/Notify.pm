package CSplat::Notify;

use strict;
use warnings;

sub notify {
  my $listener = shift;
  warn "Notify: ", @_, "\n";
  $listener->(@_);
}

1
