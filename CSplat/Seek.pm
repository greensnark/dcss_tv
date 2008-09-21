use strict;
use warnings;

package CSplat::Seek;
use base 'Exporter';

our @EXPORT_OK = qw/tty_frame_offset clear_screen/;

use CSplat::DB qw/tty_find_frame_offset tty_save_frame_offset/;
use CSplat::Ttyrec qw/ttyrec_path $TTYRDEFSZ $TTYRMINSZ tv_frame_strip/;
use CSplat::Xlog qw/desc_game_brief/;

use Term::VT102::Boundless;
use Term::TtyRec::Plus;
use Fcntl qw/SEEK_SET/;

# A standard VT102 to grab frames from.
my $TERM_X = 80;
my $TERM_Y = 24;
my $TERM = Term::VT102::Boundless->new(cols => $TERM_X, rows => $TERM_Y);

sub clear_screen {
  "\e[2J"
}

sub tv_cache_reset {
  $TERM->process(clear_screen());
  # Go to first row and reset attributes.
  $TERM->process("\e[1H\e[0m");
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
    my $text = $TERM->row_plaintext($row);
    my $tattr = $TERM->row_attr($row);
    next unless $text =~ /[^ ]/;
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
  my ($ttr, $offset, $frame) = tty_find_frame_offset($g);
  unless ($ttr && $offset && $frame) {
    ($ttr, $offset, $frame) = tty_calc_frame_offset($g, $deep);
    tty_save_frame_offset($g, $ttr, $offset, $frame) if $deep;
  }
  ($ttr, $offset, $frame)
}

sub tty_calc_frame_offset {
  my ($g, $deep) = @_;

  my $sz = $g->{sz};
  my $skipsize = 0;
  if ($sz > $TTYRDEFSZ) {
    $skipsize = $sz - $TTYRDEFSZ;
  }

  for my $ttyrec (split / /, $g->{ttyrecs}) {
    my $thisz = -s(ttyrec_path($g, $ttyrec));
    if ($skipsize >= $thisz) {
      $skipsize -= $thisz;
      $sz -= $thisz;
      next;
    }

    return tty_calc_offset_in($g, $deep, $ttyrec, $sz, $skipsize);
  }
  die "Argh, wtf?\n";
  # WTF?
  (undef, undef, undef)
}

sub tty_calc_offset_in {
  my ($g, $deep, $ttr, $rsz, $skipsz) = @_;
  if ($deep) {
    tty_find_offset_deep($g, $ttr, $rsz, $skipsz)
  }
  else {
    tty_find_offset_simple($g, $ttr, $rsz, $skipsz)
  }
}

sub frame_full_hp {
  my $line = $TERM->row_plaintext(3);
  if ($line =~ m{(?:HP|Health): (\d+)/(\d+) }) {
    if ($1 >= $2 * 85 / 100) {
      return (2, $1, $2) if $1 >= $2 * 85 / 100;
    }
    return (1, $1, $2);
  }
  (undef, undef, undef)
}

# Deep seek strategy: Look for last frame where the character had full health,
# but don't go back farther than $TTYRDEFSZ * 2.
sub tty_find_offset_deep {
  my ($g, $ttyrec, $tsz, $skip) = @_;

  print "Deep scanning for start frame for\n" . desc_game_brief($g) . "\n";
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
    return ($ttyrec, 0, '');
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
      if $hasclear && ($tsz - $pos) <= $TTYRDEFSZ * 2;

    $building = 1 if !$building && defined $lastgoodclear;

    print "Examining frame $frame ($pos / $size)\r" unless $frame % 13;

    if ($building) {
      tv_cache_frame(tv_frame_strip($fref->{data}));
      my ($type, $hp, $maxhp) = frame_full_hp();
      if ($type
          && ($type > $best_type || ($type == $best_type && $hp >= $best_hp))
          && ($tsz - $pos) <= $TTYRDEFSZ * 6)
      {
        $best_type = $type;
        $best_hp = $hp;
        $best_maxhp = $maxhp;

        $last_full_hp = $pos;
        $last_full_hp_frame = tv_frame();
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
        seek($t->filehandle(), $lastgoodclear || $lastclear, SEEK_SET);
        $building = 1;
        next;
      }

      # If we have a full hp frame, return that.
      if ($last_full_hp_frame) {
        print "\nFound full hp frame $best_type ($best_hp/$best_maxhp) ",
          "with size left (", ($tsz - $last_full_hp),
          ", avg wanted: $TTYRDEFSZ)!\n";
        return ($ttyrec, $last_full_hp, $last_full_hp_frame);
      }
      print "\nReturning frame at default seek\n";
      return ($ttyrec, $pos, tv_frame());
    }
    $prev_frame = $pos;
  }
  die "Unexpected end of ttyrec $ttyrec\n";
  (undef, undef, undef)
}

# This is the lightweight seek strategy. Can be used for on-the-fly seeking.
sub tty_find_offset_simple {
  my ($g, $ttyrec, $total_size, $skip, $buildup_from) = @_;
  my $ttyfile = ttyrec_path($g, $ttyrec);

  my $size = -s $ttyfile;
  my $skipsize = 0;

  if ($skip) {
    $skipsize = $skip if $skip > 0 && $skip < $size;
  }

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
      $prev_frame = $pos;

      my $hasclear = index($fref->{data}, $clr) > -1;
      $lastclear = $pos if $hasclear;
      $lastgoodclear = $pos if $hasclear && $total_size - $pos >= $TTYRMINSZ;

      if ($buildup_from && $pos >= $buildup_from) {
        tv_cache_frame(tv_frame_strip($fref->{data}));
      }

      next if $pos < $skipsize;

      if ($hasclear) {
        my $size_left = $total_size - $pos;
        if ($size_left < $TTYRMINSZ && $lastgoodclear < $pos
            && $total_size - $lastgoodclear >= $TTYRMINSZ
            && !$buildup_from)
        {
          close($t->filehandle());
          return tty_find_offset_simple($g, $ttyrec, $total_size,
                                        $skipsize, $lastgoodclear);
        }

        undef $skipsize;
      } else {
        # If we've been building up a frame in our VT102, spit that out now.
        if ($buildup_from && $buildup_from < $pos) {
          close($t->filehandle());
          return ($ttyrec, $pos, tv_frame());
        }
        next;
      }
    }
    close($t->filehandle());
    return ($ttyrec, $prev_frame, '');
  }
  # If we get here, ouch.
  (undef, undef, undef)
}

1
