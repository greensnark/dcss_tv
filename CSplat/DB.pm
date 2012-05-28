use strict;
use warnings;

use DBI;

package CSplat::DB;
use base 'Exporter';
use lib '..';

our @EXPORT_OK = qw/%PLAYED_GAMES exec_query exec_do exec_all
                    in_transaction query_one open_db
                    load_played_games fetch_all_games record_played_game
                    clear_played_games purge_log_offsets
                    tty_precalculated_frame_offset tty_save_frame_offset
                    tty_delete_frame_offset last_row_id check_dirs/;

use CSplat::Xlog qw/xlog_hash/;
use CSplat::Config qw/$DATA_DIR $TTYREC_DIR/;
use File::Path;

my $DBH;
my $TRAIL_DB = 'data/splat.db';

our %PLAYED_GAMES;  # hash tracking db ids of ttyrecs played

sub check_dirs {
  mkpath( [ $DATA_DIR, $TTYREC_DIR ] );
}

sub in_transaction {
  my $sub = shift;
  $DBH->begin_work;
  eval {
    $sub->();
  };
  $DBH->commit;
  die $@ if $@;
}

sub last_row_id {
  $DBH->last_insert_id(undef, undef, undef, undef)
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

sub exec_query_all {
  my ($query, @pars) = @_;
  exec_query($query, @pars)->fetchall_arrayref()
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
  check_dirs();
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

sub create_tables {
  my $dbh = shift;
  print "Setting up splat database\n";

  my $sql = do { local (@ARGV, $/) = 'csplat.sql'; <> };
  for my $st (split /;/, $sql) {
    $dbh->do($st) or die "Can't create table schema ($st)!";
  }
}

sub reopen_db {
  close_db();
  open_db();
}

sub cap_game_seek {
  my ($v, $min, $max) = @_;
  $v = $min if $v < $min && $v != -100;
  $v = $max if $v > $max;
  $v
}

sub _safenum {
  my ($s, $defval) = @_;

  $defval ||= 1;

  $s = '' unless defined $s;
  return -100 if $s eq '$';
  return 0 if $s eq '0';

  s/^\s+//, s/\s+$// for $s;

  if ($s =~ /^[+-]?\d+(?:\.\d+)?$/) {
    $s
  }
  else {
    $defval
  }
}

sub game_seek_multipliers {
  my $g = shift;

  my $preseek = _safenum($g->{seekbefore});
  my $postseek = _safenum($g->{seekafter}, 0.5);
  $postseek = 0.5 unless $g->{milestone};

  $preseek = cap_game_seek($preseek, -20, 20);
  $postseek = cap_game_seek($postseek, -20, 20);

  ($preseek, $postseek)
}

sub delete_game {
  my $g = shift;
  print "Discarding game: ", CSplat::Xlog::desc_game($g), "\n";

  # Don't delete ttyrecs yet - they could be used by multiple entries.

  exec_query("DELETE FROM games WHERE id = ?", $g->{id});
  $g->{deleted} = 'y';
}

sub tty_precalculated_frame_offset {
  my $g = shift;

  my ($pre, $post) = game_seek_multipliers($g);
  my $st = exec_query("SELECT ttyrec, offset, stop_offset, frame
                       FROM ttyrec_offset
                       WHERE id = ? AND seekbefore = ?
                         AND seekafter = ?", $g->{id}, $pre, $post);
  my $row = $st->fetchrow_arrayref();
  $row ? @$row : (undef, undef, undef, undef)
}

sub tty_delete_frame_offset {
  my $g = shift;
  exec_query("DELETE FROM ttyrec_offset WHERE id = ?", $g->{id});
}

sub tty_save_frame_offset {
  my ($g, $ttr, $offset, $stop_offset, $frame) = @_;
  my ($pre, $post) = game_seek_multipliers($g);

  if ($pre == 1 && $post == 0.5) {
    tty_delete_frame_offset($g);
    exec_query("INSERT INTO ttyrec_offset
                (id, ttyrec, offset, stop_offset, frame, seekbefore, seekafter)
                VALUES (?, ?, ?, ?, ?, ?, ?)",
               $g->{id}, $ttr, $offset, $stop_offset, $frame,
               $pre, $post);
  }
}

sub fetch_all_games {
  my %pars = @_;

  my $all = $pars{splat} && $pars{splat} eq '*';
  delete $pars{splat} if $all;

  my $rows =
    defined($pars{splat})?
      exec_query_all("SELECT id, logrecord, ttyrecs FROM games
                      WHERE etype = ?", $pars{splat}) :
    $all? exec_all("SELECT id, logrecord, ttyrecs FROM games") :
    # Only return milestones if the caller asks for them explicitly.
    exec_all("SELECT id, logrecord, ttyrecs FROM games
              WHERE etype <> 'm'");

  my @games;
  for my $row (@$rows) {
    my $id = $row->[0];
    my $g = xlog_hash($row->[1]);
    $g->{ttyrecs} = $row->[2];
    $g->{id} = $id;
    $g->{splat} = $pars{splat};
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
