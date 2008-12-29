#! /usr/bin/perl

use strict;
use warnings;

while (1) {
  print "> ";
  my $text = <>;
  last unless defined $text;
  $text =~ s/\\e/\e/g;
  print $text;
  sleep 1;
  print "\e[2J\e[1H";
}
