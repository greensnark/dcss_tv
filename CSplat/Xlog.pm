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
  $time =~ s/^(\d{4})(\d{2})/ sprintf "%04d%02d", $1, $2 + 1 /e;
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
  my $field = shift() || '';
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
  my $god = $g->{god} ? ", worshipper of $g->{god}" : "";
  my $dmsg = $g->{vmsg} || $g->{tmsg} || $g->{milestone};
  my $place = $g->{place};
  my $ktyp = $g->{ktyp} || '';

  my $prep = grep($_ eq $place, qw/Temple Blade Hell/)? "in" : "on";
  $prep = "in" if $g->{ltyp} ne 'D';
  $place = "the $place" if grep($_ eq $place, qw/Temple Abyss/);
  $place = "a Labyrinth" if $place eq 'Lab';
  $place = "a Bazaar" if $place eq 'Bzr';
  $place = "Pandemonium" if $place eq 'Pan';
  $place = " $prep $place";

  $place = '' if $ktyp eq 'winning' || $ktyp eq 'leaving';

  my $when = " on " . fix_crawl_time($g->{end} || $g->{time});

  "$g->{name} the $g->{title} (L$g->{xl} $g->{char})$god, $dmsg$place$when, " .
    "after $g->{turn} turns"
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
  my $xl = "$$g{xl}";
  $xl = " $xl" if length($xl) == 1;
  # Name, Title, XL, God, place, tmsg.
  my @pieces = (pad(14, $$g{name}),
                "L$xl $$g{char}",
                pad_god(10, $$g{god}),
                pad(7, $$g{place}),
                $$g{tmsg} || $$g{milestone});
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
  my $end = $g->{end} || $g->{time};
  "$g->{name}|$end|$g->{src}"
}

1
