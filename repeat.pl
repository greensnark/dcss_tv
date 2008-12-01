#! /usr/bin/perl

use strict;
use warnings;

die "No commands specified\n" unless @ARGV;

while (1) {
  system @ARGV;
}
