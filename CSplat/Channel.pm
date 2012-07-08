use strict;
use warnings;

package CSplat::Channel;

use lib '..';

use File::Spec;
use File::Path qw/make_path/;

our $CHANNEL_DEF_DIR = 'channels';

sub create_channel_directory {
  my ($self, $dir) = @_;
  $dir ||= $CHANNEL_DEF_DIR;
  unless (-d $dir) {
    make_path($dir) or die "Could not make directory: $dir\n";
  }
}

sub channel_def_file {
  my $channel = shift;
  File::Spec->catfile($CHANNEL_DEF_DIR, "$channel.def")
}

sub channel_def {
  my $channel = shift;
  return unless channel_exists($channel);
  my $file = channel_def_file($channel);
  open my $inf, '<', $file or die "Can't open $file: $!\n";
  chomp(my $def = do { local $/; <$inf> });

  my @queries = split /;;/, $def;
  for my $query (@queries) {
    $query =~ s/^\s+|\s+$//g;
    if ($query =~ /^\?\?/) {
      $query =~ s/\[\S+?\]$//;
      $query .= "[any]";
    } else {
      if ($query !~ /-tv/) {
        $query .= " -tv";
      }
      $query .=" -random";
    }
  }
  join(" ;; ", @queries)
}

sub channel_exists {
  my $channel = shift;
  -f channel_def_file($channel)
}

sub password_file {
  my $channel = shift;
  File::Spec->catfile($CHANNEL_DEF_DIR, "$channel.pwd")
}

sub generate_password_file {
  my $channel = shift;
  my $password_file = password_file($channel);
  unless (-f $password_file) {
    system("dd if=/dev/urandom bs=18 count=1 2>/dev/null | base64 > \Q$password_file");
  }
  $password_file
}

1
