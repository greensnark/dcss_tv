use strict;
use warnings;

package CSplat::Seek;
use base 'Exporter';
use lib '..';

our @EXPORT_OK = qw/tty_frame_offset clear_screen set_buildup_size/;

use CSplat::Ttyrec qw/ttyrec_path ttyrec_file_time
                      $TTYRDEFSZ $TTYRMINSZ tv_frame_strip/;
use CSplat::Xlog qw/desc_game_brief/;
use CSplat::TurnSeek;
use CSplat::GameTimestamp;
use CSplat::TtyPlayRange;

use Term::VT102;
use Term::TtyRec::Plus;
use Fcntl qw/SEEK_SET/;
use Carp;

# A standard VT102 to grab frames from.
my $TERM_X = 80;
my $TERM_Y = 24;
my $TERM = Term::VT102->new(cols => $TERM_X, rows => $TERM_Y);

our $MS_SEEK_BEFORE = $TTYRDEFSZ;

# Default seek after is 0.5 x this.
our $MS_SEEK_AFTER  = $TTYRDEFSZ;

our $BUILDUP_SIZE = $TTYRDEFSZ * 3;

sub set_buildup_size {
  my $sz = shift;
  $BUILDUP_SIZE = $TTYRDEFSZ * ($sz || 3);
}

sub set_default_playback_multiplier {
  my $sz = shift;
  $TTYRDEFSZ *= $sz;
}

sub clear_screen {
  "\e[2J"
}

sub tv_cache_reset {
  $TERM->reset();
  $TERM->resize($TERM_X, $TERM_Y);
  $TERM->process(clear_screen() . "\ec");
}

sub tv_cache_frame {
  $TERM->process($_[0]);
}

sub tv_chattr_s {
  my $attr = shift;
  my ($fg, $bg, $bo, $fa, $st, $ul, $bl, $rv) = $TERM->attr_unpack($attr);

  my @attr;
  push @attr, 1 if $bo || $st;
  push @attr, 2 if $fa;
  push @attr, 4 if $ul;
  push @attr, 5 if $bl;
  push @attr, 7 if $rv;

  my $attrs = @attr? join(';', @attr) . ';' : '';
  "\e[0;${attrs}3$fg;4${bg}m"
}

# Return the current term contents as a single frame that can be written
# to a terminal.
sub tv_frame {
  my $frame = "\e[2J\e[0m";
  my $lastattr = '';
  for my $row (1 .. $TERM->rows()) {
    my $text = $TERM->row_text($row);
    next unless $text =~ /[^\0 ]/;

    $text =~ tr/\0/ /;
    my $tattr = $TERM->row_attr($row);
    $frame .= "\e[${row}H";
    for (my $i = 0; $i < $TERM->cols(); ++$i) {
      my $attr = substr($tattr, $i * 2, 2);
      $frame .= tv_chattr_s($attr) if $attr ne $lastattr;
      $frame .= substr($text, $i, 1);
      $lastattr = $attr;
    }
  }

  my ($x, $y, $attr) = $TERM->status();
  $frame .= "\e[$y;${x}H";
  $frame .= tv_chattr_s($attr) unless $attr eq $lastattr;

  $frame
}

sub tty_frame_offset {
  my ($g, $deep) = @_;
  my $play_range = tty_calc_frame_offset($g, $deep);
  $play_range
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

sub tty_calc_frame_offset {
  my ($g, $deep) = @_;

  my ($seekbefore, $seekafter) = game_seek_multipliers($g);
  print "Seeking (<$seekbefore, >$seekafter) for start frame for ",
    CSplat::Xlog::desc_game($g), "\n";

  my $milestone = $g->{milestone};
  my ($start_offset, $end_offset, $start_ttyrec, $end_ttyrec);

  my @ttyrecs = split / /, $g->{ttyrecs};

  my $ttyrec_total_size = 0;
  for my $ttyrec (@ttyrecs) {
    $ttyrec_total_size += -s(ttyrec_path($g, $ttyrec));
  }

  $end_ttyrec = $ttyrecs[$#ttyrecs];

  my $turn_seek = CSplat::TurnSeek->new($g);
  print "Turn seek: " . $turn_seek->str() . "\n" if $turn_seek;

  # For regular games, the implicit end time is the end of the last ttyrec.
  # For milestones and turn-based TV requests, the end time is explicit:
  my $explicit_end_time = $turn_seek && $turn_seek->end_time();
  if ($explicit_end_time) {
    # Work out where exactly the milestone starts.
    my ($start, $end, $seek_frame_offset) =
      CSplat::Ttyrec::ttyrec_play_time($g, $end_ttyrec, $explicit_end_time);

    die "Broken ttyrec\n" unless defined($start) && defined($end);

    # The frame involving the milestone should be treated as EOF.
    $end_offset = $seek_frame_offset;
  }

  my $first_ttyrec_start_time = ttyrec_file_time($ttyrecs[0]);

  # We may have an explicit start time, and hence an explicit start offset
  # if the user specified a turn-based start point, say using <T1.
  my $explicit_start_time =
    $turn_seek && $turn_seek->start_time($first_ttyrec_start_time);
  print "Explicit start time: $explicit_start_time (first ttyrec: $first_ttyrec_start_time)\n";
  if ($explicit_start_time) {
    $start_ttyrec = $ttyrecs[0];
    my ($start, $end, $seek_frame_offset) =
      CSplat::Ttyrec::ttyrec_play_time($g, $start_ttyrec, $explicit_start_time);
    $start_offset = $seek_frame_offset;
  }

  # If we don't know where playback starts, set start and end to the
  # same offsets. This does not mean nothing will be played back: the
  # playback prelude size will govern the length of playback.
  #
  # This is the *most common case*, where the user did not specify a
  # start-turn.
  if (!defined($start_offset)) {
    $start_offset = $end_offset || -s(ttyrec_path($g, $end_ttyrec));
    $start_ttyrec = $end_ttyrec;
  }

  # size_before_playback_frame == size of ttyrec(s) before the start
  # frame offset, ignoring the playback prelude.
  my $size_before_playback_frame = 0;
  for my $ttyrec (@ttyrecs) {
    my $ttyrec_size = -s(ttyrec_path($g, $ttyrec));
    print "ttyrec: $ttyrec, start: $start_ttyrec, size_before_frame: $size_before_playback_frame, tty size: $ttyrec_size\n";
    if ($ttyrec eq $start_ttyrec) {
      $size_before_playback_frame += $start_offset;
      last;
    }
    $size_before_playback_frame += $ttyrec_size;
  }

  # The playback skip size is the size of the ttyrec(s) that are never
  # displayed to the viewer. This is the amount of ttyrec before
  # playback starts.
  my $playback_skip_size = 0;

  # The playback prelude is the size of the playback before the actual
  # ttyrec event that the viewer wants to see. For instance, when
  # viewing a death with !lg *, the prelude size is the amount of
  # ttyrec played back before the end of the game. For !lm, the
  # prelude is the amount of ttyrec played back before the milestone.
  #
  # If the user requested a hard start *turn*, the prelude
  # disappeared.
  my $playback_prelude_size = $explicit_end_time ? $MS_SEEK_BEFORE : $TTYRDEFSZ;

  if ($explicit_start_time && $turn_seek->hard_start_time()) {
    $playback_prelude_size = 0;
  } else {
    # If the game itself requests a specific seek, oblige. This is activated
    # by <X, such as <3
    $playback_prelude_size *= $seekbefore unless $explicit_start_time;
  }

  my $delbuildup = $BUILDUP_SIZE - $TTYRDEFSZ;

  local $BUILDUP_SIZE = $playback_prelude_size + $delbuildup;

  if ($size_before_playback_frame > $playback_prelude_size) {
    $playback_skip_size = $size_before_playback_frame - $playback_prelude_size;
    if ($playback_skip_size >= $ttyrec_total_size) {
      $playback_skip_size = $ttyrec_total_size - 1;
    }
  }

  for my $ttyrec (@ttyrecs) {
    my $ttyrec_size = -s(ttyrec_path($g, $ttyrec));
    print "Considering $ttyrec, size: $ttyrec_size, skip size: $playback_skip_size\n";
    if ($playback_skip_size >= $ttyrec_size) {
      $playback_skip_size -= $ttyrec_size;
      $size_before_playback_frame -= $ttyrec_size;
      next;
    }

    my $ignore_hp = $explicit_end_time;
    my ($ttr, $offset, $stop_offset, $frame) =
      tty_calc_offset_in($g, $deep, $ttyrec, $size_before_playback_frame,
                         $playback_skip_size, $ignore_hp);

    # Seek won't presume to set a stop offset, so do so here.
    if ($explicit_end_time && !defined($stop_offset) && defined($end_offset)
        && $seekafter != -100)
    {
      print "Seek after: $seekafter\n";
      if ($turn_seek && $turn_seek->hard_end_time()) {
        $stop_offset = $end_offset;
      } else {
        my $endpad = $MS_SEEK_AFTER;
        $endpad *= $seekafter;
        $stop_offset = $end_offset + $endpad;
      }
    }
    print "Play range: start: $ttr, offset: $offset, end: $end_ttyrec, end_offset: $stop_offset\n";
    return CSplat::TtyPlayRange->new(start_file => $ttr,
                                     start_offset => $offset,
                                     end_file => $end_ttyrec,
                                     end_offset => $stop_offset,
                                     frame => $frame);
  }
  confess "Argh, wtf?\n";
  # WTF?
  (undef, undef, undef, undef)
}

sub tty_calc_offset_in {
  my ($g, $deep, $ttyrec, $size_before_start_frame,
      $skip_size, $ignore_hp) = @_;
  if ($deep) {
    tty_find_offset_deep($g, $ttyrec, $size_before_start_frame,
                         $skip_size, $ignore_hp)
  }
  else {
    tty_find_offset_simple($g, $ttyrec, $size_before_start_frame,
                           $skip_size)
  }
}

sub frame_full_hp {
  my $line = $TERM->row_plaintext(3);
  if ($line =~ m{(?:HP|Health): (\d+)/(\d+) } && $1 <= $2) {
    return (2, $1, $2) if $1 >= $2 * 85 / 100;
    return (1, $1, $2);
  }
  (undef, undef, undef)
}

# Deep seek strategy: Look for last frame where the character had full health,
# but don't go back farther than $TTYRDEFSZ * 2.
sub tty_find_offset_deep {
  my ($g, $ttyrec, $tsz, $skip, $ignore_hp) = @_;

  my $hp = $ignore_hp ? $ignore_hp : '';
  print "Deep scanning for start frame (sz: $tsz, skip: $skip, hp_ignore: $hp) for\n" . desc_game_brief($g) . "\n";
  local $| = 1;

  tv_cache_reset();
  my $ttyfile = ttyrec_path($g, $ttyrec);
  my $t = Term::TtyRec::Plus->new(infile => $ttyfile,
                                  time_threshold => 3);

  my $size = -s $ttyfile;
  my $skipsize = 0;
  if ($skip) {
    $skipsize = $skip if $skip > 0 && $skip < $size;
  }

  if (!$skipsize) {
    return ($ttyrec, 0, undef, '');
  }

  my $prev_frame = 0;
  my $last_full_hp = 0;
  my $last_full_hp_frame = '';
  my $clr = clear_screen();
  my $building;

  my $best_type = 0;
  my $best_hp = 0;
  my $best_maxhp = 0;

  my $lastclear;
  my $lastgoodclear;
  while (my $fref = $t->next_frame()) {
    my $frame = $t->frame();
    my $pos = tell($t->filehandle());

    my $hasclear = index($fref->{data}, $clr) > -1;

    $lastclear = $prev_frame if $hasclear;
    $lastgoodclear = $prev_frame
      if $hasclear && ($tsz - $pos) <= $BUILDUP_SIZE;

    $building = 1 if !$building && defined $lastgoodclear;

    print "Examining frame $frame ($pos / $size)\r" unless $frame % 3031;

    if ($building) {
      tv_cache_frame(tv_frame_strip($fref->{data}));
      unless ($ignore_hp) {
        my ($type, $hp, $maxhp) = frame_full_hp();
        if ($type
            && ($type > $best_type || ($type == $best_type && $hp >= $best_hp))) {
          $best_type = $type;
          $best_hp = $hp;
          $best_maxhp = $maxhp;

          $last_full_hp = $pos;
          $last_full_hp_frame = tv_frame();
        }
      }
    }

    if ($pos >= $skipsize) {
      close($t->filehandle());

      # Ack, we found no good place to build up frames from, restart
      # with a forced start point.
      unless ($building) {
        undef $t;
        $t = Term::TtyRec::Plus->new(infile => $ttyfile,
                                     time_threshold => 3);
        seek($t->filehandle(), $lastgoodclear || $lastclear || 0, SEEK_SET);
        $building = 1;
        next;
      }

      # If we have a full hp frame, return that.
      if ($last_full_hp_frame) {
        print "\nFound full hp frame $best_type ($best_hp/$best_maxhp) ",
          "with size left (", ($tsz - $last_full_hp),
          ", avg wanted: $TTYRDEFSZ)!\n";
        return ($ttyrec, $last_full_hp, undef, $last_full_hp_frame);
      }
      print "\nReturning frame at default seek ($pos / $tsz)\n";
      return ($ttyrec, $pos, undef, tv_frame());
    }
    $prev_frame = $pos;
  }
  warn "Unexpected end of ttyrec $ttyrec\n";
  (undef, undef, undef, undef)
}

sub ttyrec_seek_frame {
  my ($g, $ttyrec, $size_before_start_frame, $skip, $buildup_from,
      $playback_start_frame) = @_;
  if (-x 'bin/ttyrec-seek-frame') {
    my $ttyrec_file_path = ttyrec_path($g, $ttyrec);
    my $command =
      qq{./bin/ttyrec-seek-frame $ttyrec_file_path $playback_start_frame};

    local $SIG{CHLD};
    my $output = tv_frame_strip(qx{$command});
    my $res = $?;
    if ($res >> 8) {
      warn "$command execution failed ($res)\n";
    } else {
      return ($ttyrec, $playback_start_frame, undef, $output);
    }
  }

  tty_find_offset_simple($g, $ttyrec, $size_before_start_frame, $skip,
                         $buildup_from)
}

# This is the lightweight seek strategy. Can be used for on-the-fly seeking.
sub tty_find_offset_simple {
  my ($g, $ttyrec, $size_before_start_frame, $skip, $buildup_from) = @_;
  my $ttyfile = ttyrec_path($g, $ttyrec);

  my $size = -s $ttyfile;
  my $skipsize = 0;

  if ($skip) {
    $skipsize = $skip if $skip > 0 && $skip <= $size;
  }

  no warnings qw/uninitialized/;
  print("tty_find_offset_simple: game: " . desc_game_brief($g) . ", " .
        "ttyrec: $ttyrec, size_before_start_frame: $size_before_start_frame:, skip: $skip (accepted skip: $skipsize), " .
        "buildup_from: $buildup_from\n");

  my $t = Term::TtyRec::Plus->new(infile => $ttyfile,
                                  time_threshold => 3);
  my $lastclear = 0;
  my $lastgoodclear = 0;

  tv_cache_reset();

  my $prev_frame = 0;
  my $clr = clear_screen();
  while (my $fref = $t->next_frame()) {
    if ($skipsize) {
      my $pos = tell($t->filehandle());
      my $hasclear = $prev_frame == 0 || index($fref->{data}, $clr) > -1;
      $lastclear = $prev_frame if $hasclear;
      if ($hasclear && $size_before_start_frame - $pos >= $TTYRMINSZ) {
        $lastgoodclear = $prev_frame;
      }
      $prev_frame = $pos;

      if (defined($buildup_from) && $pos >= $buildup_from) {
        tv_cache_frame(tv_frame_strip($fref->{data}));
      }

      next if $pos < $skipsize;

      if ($hasclear) {
        my $size_left = $size_before_start_frame - $pos;
        if ($size_left < $TTYRMINSZ && $lastgoodclear < $pos
            && $size_before_start_frame - $lastgoodclear >= $TTYRMINSZ
            && !defined($buildup_from))
        {
          close($t->filehandle());
          return ttyrec_seek_frame($g, $ttyrec, $size_before_start_frame,
                                   $skipsize, $lastgoodclear, $pos);
        }

        undef $skipsize;
      } else {
        if (defined($buildup_from)) {
          # If we've been building up a frame in our VT102, spit that out now.
          if ($buildup_from < $pos) {
            close($t->filehandle());
            return ($ttyrec, $pos, undef, tv_frame());
          }
        }
        # Last effort: if there is a screen-clear within the VT102
        # build-up size threshold, go back and build up frames from
        # there.
        elsif ($pos - ($lastgoodclear || $lastclear) <= $BUILDUP_SIZE) {
          close($t->filehandle());
          return ttyrec_seek_frame($g, $ttyrec, $size_before_start_frame,
                                   $skipsize,
                                   $lastgoodclear || $lastclear,
                                   $pos);
        }
        next;
      }
    }

    # No frame build-up possible, hopefully this is the start of a
    # ttyrec (good) or this frame has a screen clear.
    close($t->filehandle());
    return ($ttyrec, $lastclear, undef, '');
  }

  # Ouch: ttyrec is broken (empty or malformed).
  (undef, undef, undef, undef)
}

1
