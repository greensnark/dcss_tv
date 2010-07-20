use strict;
use warnings;

package CSplat::Xlog;

use base 'Exporter';
our @EXPORT_OK = qw/xlog_line desc_game desc_game_brief
                    fix_crawl_time game_unique_key xlog_str
                    xlog_merge/;

our $MAX_WIDTH = 80;

sub fix_crawl_time {
  my $time = shift;
  $time
}

sub xlog_line {
  chomp(my $text = shift);
  $text =~ s/::/\n/g;
  my @fields = map { (my $x = $_) =~ tr/\n/:/; $x } split /:/, $text;
  my %hash = map /^(\w+)=(.*)/, @fields;
  \%hash
}

sub escape_xlogfield {
  my $field = shift();
  $field = '' unless defined($field);
  $field =~ s/:/::/g;
  $field
}

sub xlog_str {
  my ($xlog, $full) = @_;
  my %hash = %$xlog;
  unless ($full) {
    delete $hash{offset};
    delete $hash{ttyrecs};
    delete $hash{ttyrecurls};
  }
  join(":", map { "$_=@{[ escape_xlogfield($hash{$_}) ]}" } keys(%hash))
}

sub xlog_merge {
  my $first = shift;
  for my $sec (@_) {
    for my $key (keys %$sec) {
      $first->{$key} = $sec->{$key} unless $first->{$key};
    }
  }
  $first
}

sub desc_game {
  my $g = shift;

  my $desc = $$g{death} || $$g{mdesc};
  my $place = $$g{place};
  $place = " ($place)" if $place;
  "$$g{name} $desc$place"
}

sub pad {
  my ($len, $text) = @_;
  $text ||= '';
  $text = substr($text, 0, $len) if length($text) > $len;
  sprintf("%-${len}s", $text)
}

sub pad_god {
  my ($len, $text) = @_;
  $text ||= '';
  $text = 'TSO' if $text eq 'The Shining One';
  $text = 'Nemelex' if $text eq 'Nemelex Xobeh';
  pad($len, $text)
}

sub desc_game_brief {
  my $g = shift;
  # Name, Title, XL, God, place, tmsg.
  my @pieces = (pad(10, $$g{name}),
                $$g{death} || $$g{mdesc});
  @pieces = grep($_, @pieces);
  my $text = join("  ", @pieces);
  $text = substr($text, 0, $MAX_WIDTH) if length($text) > $MAX_WIDTH;

  if ($g->{req}) {
    my $suffix = " (r:$g->{req})";
    my $rlen = length($suffix);
    $text = pad($MAX_WIDTH - $rlen, $text) . $suffix
  }
  $text
}

sub game_unique_key {
  my $g = shift;
  my $end = $g->{endtime} || $g->{currenttime};
  "$g->{name}|$end|$g->{src}"
}

1
