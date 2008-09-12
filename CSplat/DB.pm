use strict;
use warnings;

use DBI;

package CSplat::DB;
use base 'Exporter';

our @EXPORT_OK = qw/%PLAYED_GAMES exec_query exec_do exec_all
                    in_transaction query_one open_db
                    load_played_games fetch_all_games record_played_game
                    clear_played_games purge_log_offsets/;

use CSplat::Xlog qw/xlog_line/;

my $DBH;
my $TRAIL_DB = 'data/splat.db';

our %PLAYED_GAMES;  # hash tracking db ids of ttyrecs played

sub in_transaction {
  my $sub = shift;
  $DBH->begin_work;
  eval {
    $sub->();
  };
  $DBH->commit;
  die $@ if $@;
}

sub check_exec {
  my ($query, $sub) = @_;
  while (1) {
    my $res = $sub->();
    return $res if $res;
    my $reason = $!;
    # If SQLite wants us to retry, sleep one second and take another stab at it.
    die "Failed to execute $query: $!\n"
      unless $reason =~ /temporarily unavail/i;
    sleep 1;
  }
}

sub exec_query {
  my ($query, @pars) = @_;
  my $st = $DBH->prepare($query) or die "Can't prepare $query: $!\n";
  check_exec( $query, sub { $st->execute(@pars) } );
  $st
}

sub exec_do {
  my $query = shift;
  check_exec($query, sub { $DBH->do($query) })
}

sub exec_all {
  my $query = shift;
  check_exec($query,
             sub { $DBH->selectall_arrayref($query) })
}

sub query_one {
  my ($query, @pars) = @_;
  if (@pars) {
    my $st = exec_query($query, @pars);
    my $rrow = $st->fetchrow_arrayref();
    $rrow->[0]
  }
  else {
    my $rrow = check_exec($query, sub { $DBH->selectrow_arrayref($query) });
    $rrow->[0];
  }
}

sub purge_log_offsets {
  my $purge = "DELETE FROM logplace";
  # And reset our log positions so we rescan the entire logfile.
  check_exec($purge, sub { $DBH->do("DELETE FROM logplace") });
}

sub open_db {
  my $size = -s $TRAIL_DB;
  $DBH = DBI->connect("dbi:SQLite:$TRAIL_DB");
  create_tables($DBH) unless defined($size) && $size > 0;
}

sub close_db {
  if ($DBH) {
    $DBH->disconnect();
    undef $DBH;
  }
}

sub reopen_db {
  close_db();
  open_db();
}

sub fetch_all_games {
  my $rows = exec_all("SELECT id, logrecord, ttyrecs FROM ttyrec");

  my @games;
  for my $row (@$rows) {
    my $id = $row->[0];
    my $g = xlog_line($row->[1]);
    $g->{ttyrecs} = $row->[2];
    $g->{id} = $id;
    push @games, $g;
  }
  @games
}

sub record_played_game {
  my $g = shift;
  $PLAYED_GAMES{$g->{id}} = 1;
  exec_query("INSERT INTO played_games (ref_id) VALUES (?)",
             $g->{id});
}

sub clear_played_games {
  %PLAYED_GAMES = ();
  exec_do("DELETE FROM played_games");
}

sub load_played_games {
  my $rrows = exec_all("SELECT ref_id FROM played_games");
  for my $row (@$rrows) {
    $PLAYED_GAMES{$row->[0]} = 1;
  }
}

1
