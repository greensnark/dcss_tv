package CSplat::TtyrecSource;

use strict;
use warnings;

use CSplat::TtyrecSourceDir;

sub new {
  my ($cls, $cfg) = @_;
  my @ttyrec_paths = ref($cfg) eq 'ARRAY' ? @$cfg : ($cfg);
  bless {
    _cfg => $cfg,
    _dirs => [map(CSplat::TtyrecSourceDir->new($_), @ttyrec_paths)]
  }, $cls
}

sub resolve {
  my ($self, $g) = @_;
  $self->{g} = $g;
  $self->{_dirs} = [map($_->resolve($g), $self->dirs())];
  $self
}

sub dirs {
  @{shift()->{_dirs}}
}

# Returns true if we have *any* cached directory
sub have_cached_listing {
  my ($self, $time_wanted) = @_;
  for my $source_dir ($self->dirs()) {
    return 1 if $source_dir->have_cached_listing($time_wanted);
  }
  0
}

sub clear_cached_listing {
  my $self = shift;
  for my $source_dir ($self->dirs()) {
    $source_dir->clear_cached_listing();
  }
}

sub ttyrec_urls {
  my ($self, $listener, $g, $time_wanted) = @_;
  my %merged_list;
  for my $source_dir ($self->dirs()) {
    my @ttyrecs = $source_dir->ttyrec_urls($listener, $g, $time_wanted);
    $merged_list{$_->{timestr}} = $_ for @ttyrecs;
  }
  map($merged_list{$_}, sort keys %merged_list)
}

1
