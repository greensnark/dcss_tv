use strict;
use warnings;

package CSplat::Util;

use Fcntl qw/LOCK_EX/;
use base 'Exporter';

our @EXPORT_OK = qw/run_service alarm_timeout open_logfile with_lock_do/;

sub run_service {
  my ($service_name, $action) = @_;
  my $lock_file = ".$service_name.lock";
  my $log_file = ".$service_name.log";
  print "Starting $service_name service\n";
  with_lock_do($lock_file,
               LOCK_EX,
               "another $service_name service may be running",
               5,
               sub {
                 open_logfile($log_file);
                 $action->();
               });
}

sub with_lock_do {
  my ($lock_file, $lock_mode, $failmsg, $wait_time, $action) = @_;
  my $lock_fail_msg =
    "Failed to lock $lock_file: $failmsg\n";

  my $lock_handle;
  alarm_timeout($wait_time, $failmsg,
          sub {
            open $lock_handle, '>', $lock_file or
              die "Couldn't open $lock_file: $!\n";
            flock $lock_handle, $lock_mode or die $lock_fail_msg;
          });
  $action->()
}

sub open_logfile {
  my $logfile = shift;
  open my $logf, '>', $logfile or die "Can't write $logfile: $!\n";
  $logf->autoflush;
  open STDOUT, '>&', $logf or die "Couldn't redirect stdout\n";
  open STDERR, '>&', $logf or die "Couldn't redirect stderr\n";
  STDOUT->autoflush;
  STDERR->autoflush;
}

sub alarm_timeout {
  my ($timeout, $timeout_msg, $sub) = @_;

  my $alarm_exc = "alarm\n";
  local $SIG{ALRM} =
    sub {
      die $alarm_exc;
    };
  alarm $timeout;
  my $result = eval {
    $sub->();
  };
  my $error = $@;
  alarm 0;
  if ($error) {
    if ($error eq $alarm_exc) {
      die $timeout_msg;
    }
    die $error;
  }
  $result
}


1
