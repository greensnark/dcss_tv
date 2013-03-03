package CSplat::Template;

use strict;
use warnings;

sub resolve_game_field {
  my ($field, $g) = @_;
  return canonical_game_version($g) if $field eq 'game';
  $field = 'name' if $field eq 'player';
  $$g{$field}
}

sub resolve_template {
  my ($url, $g) = @_;
  return unless $url;
  my $templated = $url =~ /\$(\w+)\$/;
  $url =~ s/\$(\w+)\$/ resolve_game_field($1, $g) /ge;
  $url .= "/$$g{name}" unless $templated;
  $url
}

1
