#! /usr/bin/perl

use strict;
use warnings;

use Getopt::Long;
use CSplat::Xlog qw/desc_game desc_game_brief game_title xlog_hash xlog_str/;
use CSplat::Ttyrec qw/request_download/;
use CSplat::Select;
use CSplat::Channel;
use CSplat::Termcast;
use CSplat::Request;
use CSplat::ChannelMonitor;
use CSplat::FileChannelManager;
use CSplat::Channel;
use CSplat::Util;
use File::Path qw/make_path/;
use TV::ChannelQuery;
use Term::TtyRec::Plus;
use IO::Socket::INET;
use Date::Manip;
use Fcntl qw/SEEK_SET/;
use threads;
use threads::shared;

my %opt;

my @queued_fetch : shared;
my @queued_playback : shared;
my @stop_list : shared;
my $TV_IS_IDLE :shared;
my $MAX_IDLE_SECONDS = 90;

my @recently_played;
my $DUPE_SUPPRESSION_THRESHOLD = 9;


END {
  kill HUP => -$$;
}

local $| = 1;

# Fetch mode by default.
GetOptions(\%opt, 'local', 'local-request',
           'simple', 'auto_channel=s', 'file_queue=s') or die;

my $CHANMAN;
unless ($opt{auto_channel}) {
  $CHANMAN = CSplat::FileChannelManager->new(\&channel_player);
}
local $SIG{CHLD} = $CHANMAN ? $CHANMAN->reaper() : 'IGNORE';

# An appropriately Crawlish number.
my $PLAYLIST_SIZE = 9;

# Socket for splat requests.
my $REQUEST_HOST = $ENV{PLAYLIST_HOST} || '127.0.0.1';
my $REQUEST_PORT = $ENV{PLAYLIST_PORT} || 21976;
my $TERMCAST_CHANNEL = $opt{auto_channel} || $ENV{TERMCAST_CHANNEL} || 'FooTV';
my $REQUEST_IRC_CHANNEL = $ENV{REQUEST_IRC_CHANNEL} || '##crawl';
my $AUTO_CHANNEL_DIR = 'channels';
my $auto_channel = $opt{auto_channel};
my $file_queue = $opt{'file_queue'};


$REQUEST_HOST = 'localhost' if $opt{'local-request'};

sub get_game_matching {
  my $g = shift;
  download_game($g)
}

sub download_notifier {
  my $msg = shift;
  push @queued_fetch, "msg: $msg";
}

sub download_game {
  my $g = shift;

  my $start = $g->{start};
  warn "Downloading ttyrecs for ", desc_game($g), "\n";

  $g->{nocheck} = 'y';
  return undef unless request_download($g, \&download_notifier);
  delete @$g{qw/nostart nocheck/};
  $g
}

sub fetch_game_for_playback {
  my ($g, $verbose) = @_;

  push @queued_fetch, xlog_str($g);
  my $game = get_game_matching($g);
  if ($game) {
    $game->{req} = $g->{req};
    push @queued_playback, xlog_str($game, 1);
  } else {
    $g->{failed} = 1;
    push @queued_fetch, xlog_str($g);
  }
}

sub game_key {
  my $g = shift;
  "$$g{name}:$$g{src}:$$g{rstart}"
}

sub dedupe_auto_footv_game {
  my $game = shift;
  my $g = canonicalize_game(xlog_hash($game));
  my $game_key = game_key($g);
  print "Considering game $game_key (recent: ", join(", ", @recently_played), "): ",
    desc_game($g), "\n";
  return undef if (grep($_ eq $game_key, @recently_played));
  push @recently_played, $game_key;
  if (@recently_played > $DUPE_SUPPRESSION_THRESHOLD) {
    shift @recently_played;
  }
  $g
}

sub queue_games_automatically {
  my $channel_def;
  my $query;
  while (1) {
    if (!CSplat::Channel::channel_exists($TERMCAST_CHANNEL)) {
      warn "Channel $TERMCAST_CHANNEL no longer exists, terminating\n";
      terminate_auto_footv();
    }

    my $def = CSplat::Channel::channel_def($TERMCAST_CHANNEL);
    if (!$channel_def || $def ne $channel_def) {
      $channel_def = $def;
      print "Channel definition: $TERMCAST_CHANNEL => $channel_def\n";
      $query = TV::ChannelQuery->new($channel_def);
    }

    my $list_attempts = 30;
    while (@queued_playback < 5 && $list_attempts-- > 0) {
      print "Asking channel server for next game for $TERMCAST_CHANNEL\n";
      my $game = $query->next_game();
      unless ($game) {
        print "Channel server provided no game for $def, will retry later\n";
        last;
      }

      my $nondupe_game = dedupe_auto_footv_game($game);
      if ($nondupe_game) {
        fetch_game_for_playback($nondupe_game);
      }
    }
    sleep 3;
  }
}

sub canonicalize_game {
  my $g = shift;
  return $g unless $g;
  $g->{start} = $g->{rstart};
  $g->{end} = $g->{rend};
  $g->{time} = $g->{rtime};
  $g
}

sub next_request {
  my ($REQ) = @_;
  my $g;

  $g = canonicalize_game($REQ->next_request());

  if (!$g) {
    if ($file_queue && $TV_IS_IDLE) {
      print "Playlist empty and TV idle, exiting\n";
      $REQ->delete_file_queue();
      exit;
    }
    return;
  }

  $g->{cancel} = 'y' if ($g->{nuke} || '') eq 'y';

  if (defined($g->{channel}) && !$file_queue && $CHANMAN) {
    eval {
      $CHANMAN->game_request($g);
    };
    if ($@) {
      push @queued_fetch, "msg: Bad request: $@";
    }
    return;
  }

  if (($g->{cancel} || '') eq 'y') {
    my $filter = CSplat::Select::make_filter($g);
    $filter = { } if $g->{nuke};
    @queued_playback =
      grep(!CSplat::Select::filter_matches($filter, xlog_hash($_)),
           @queued_playback);

    warn "Adding ", desc_game($g), " to stop list\n";
    push @stop_list, xlog_str($g);
    push @queued_fetch, xlog_str($g);
  }
  else {
    fetch_game_for_playback($g, 'verbose');
  }
}

sub check_irc_requests {
  my $REQ = CSplat::Request->new(host => $REQUEST_HOST,
                                 port => $REQUEST_PORT,
                                 file_queue => $file_queue);

  while (1) {
    next_request($REQ);
    sleep 1;
  }
}

sub terminate_auto_footv {
  print "Channel $TERMCAST_CHANNEL went away, exiting\n";
  exit 0;
}

sub check_requests {
  if ($opt{auto_channel} && !$file_queue && !$opt{simple}) {
    queue_games_automatically();
  }
  else {
    check_irc_requests();
  }
}

sub channel_game_title {
  my %g = %{shift()};
  if ($g{req} ne $TERMCAST_CHANNEL && $g{req} ne 'Henzell') {
    $g{extra} = join(",", $g{extra} || '', 'req');
  }
  game_title(\%g)
}

sub tv_show_playlist {
  my ($TV, $rplay, $prev) = @_;

  $TV->clear();
  if (@$rplay) {
    $TV->title(channel_game_title($$rplay[0]));
  }

  if ($prev) {
    $prev = desc_game_brief($prev);
    $TV->write("\e[1H\e[1;37mLast game played:\e[0m\e[2H\e[1;33m$prev.\e[0m");
  }

  my $pos = 1 + ($prev ? 3 : 0);
  $TV->write("\e[$pos;1H\e[1;37mComing up:\e[0m");
  $pos++;

  my $first = 1;
  my @display = @$rplay;
  if (@display > $PLAYLIST_SIZE) {
    @display = @display[0 .. ($PLAYLIST_SIZE - 1)];
  }
  for my $game (@display) {
    # Move to right position:
    $TV->write("\e[$pos;1H",
               $first? "\e[1;34m" : "\e[0m",
               desc_game_brief($game));
    if ($first) {
      $TV->write("\e[0m");
    }
    undef $first;
    ++$pos;
  }
}

sub cancel_playing_games {
  if (@stop_list) {
    my @stop = @stop_list;
    @stop_list = ();

    my $g = shift;

    if (grep /nuke=y/, @stop) {
      return 'stop';
    }

    my @filters = map(CSplat::Select::make_filter(xlog_hash($_)), @stop);
    if (grep(CSplat::Select::filter_matches($_, $g), @filters)) {
      return 'stop';
    }
  }
}

sub update_status {
  my ($TV, $line, $rlmsg, $slept, $rcountup) = @_;
  my $xlog = $line !~ /^msg: /;

  if ($xlog) {
    my $f = xlog_hash($line);
    $$f{req} ||= $TERMCAST_CHANNEL;
    if (($f->{cancel} || '') eq 'y') {
      if ($f->{nuke}) {
        $TV->write("\e[1;35mPlaylist clear by $f->{req}\e[0m\r\n");
      } else {
        $TV->write("\e[1;35mCancel by $f->{req}\e[0m\r\n",
                   desc_game_brief($f), "\r\n");
      }
      $$rlmsg = $slept + 1;
    } elsif ($f->{failed}) {
      $TV->write("\e[1;31mFailed to fetch game:\e[0m\r\n",
                 desc_game_brief($f), "\r\n");
      $$rlmsg = $slept + 1;
    } else {
      $TV->write("\e[1;34mRequest by $$f{req}:\e[0m\r\n",
                 desc_game_brief($f), "\r\n");
      $TV->title(channel_game_title($f));
      $TV->write("\r\nPlease wait, fetching game...\r\n");
      undef $$rlmsg;
    }
    $$rcountup = 1;
  }
  else {
    ($line) = $line =~ /^msg: (.*)/;
    $TV->write("$line\r\n");
  }
}

sub exec_channel_player {
  my ($channel, $file_queue) = @_;
  make_path('channels/logs');
  my $logfile = "channels/logs/${channel}.log";
  CSplat::Util::open_logfile($logfile);

  my $cmd = "perl $0 --auto_channel \Q$channel";
  if ($file_queue) {
    $cmd .= " --file_queue \Q$file_queue";
  }
  if ($opt{local}) {
    $cmd .= " --local";
  }
  exec($cmd)
}

sub channel_player {
  my ($channel, $file_queue) = @_;
  my $player_pid = fork();
  if (!$player_pid) {
    exec_channel_player($channel, $file_queue);
    exit;
  }
  $player_pid
}

sub channel_monitor {
  my $channel_monitor = CSplat::ChannelMonitor->new(\&channel_player);
  $channel_monitor->run;
}

# Starts the thread to monitor for custom channels.
sub start_channel_monitor {
  my $channel_monitor = threads->new(\&channel_monitor);
  $channel_monitor->detach;
  $channel_monitor
}

sub channel_password_file {
  if ($opt{auto_channel}) {
    CSplat::Channel::generate_password_file($TERMCAST_CHANNEL)
  }
  else {
    "$TERMCAST_CHANNEL.pwd"
  }
}

sub flag_idle {
  my $TV = shift;
  $TV->title("[waiting]");
}

sub automatic_channels_supported {
  !$opt{local} && !$opt{auto_channel} && !$opt{simple} && !$opt{single_game};
}

sub tv_currently_idle {
  !@queued_fetch && !@queued_playback
}

sub request_tv {
  print("Connecting to TV: name: $TERMCAST_CHANNEL, passfile: ", channel_password_file(), "\n");
  my $TV = CSplat::Termcast->new(name => $TERMCAST_CHANNEL,
                                 passfile => channel_password_file(),
                                 local => $opt{local});

  my $last_game;

  if (!$opt{local} && !$opt{auto_channel} && !$opt{simple}) {
    start_channel_monitor();
  }

  my $rcheck = threads->new(\&check_requests);
  $rcheck->detach;

  $TV->callback(\&cancel_playing_games);
  $TV->clear();

  my $idle_begin;

 RELOOP:
  while (1) {
    flag_idle($TV);
    if ($last_game) {
      $TV->clear();
      $TV->at(1);
      $TV->color(qw/white/)->write("That was:");
      $TV->write("\r\n");
      $TV->color(qw/bold yellow/)->write(desc_game_brief($last_game));
      $TV->color()->write("\r\n\r\n");
    }

    unless ($opt{auto_channel}) {
      $TV->write("Waiting for requests (see ??FooTV on $REQUEST_IRC_CHANNEL to request a game).");
      $TV->write("\r\n\r\n");
    }

    my $slept = 0;
    my $last_msg = 0;
    my $countup;
    my $idle_warning_shown;
    while (1) {
      my $idle_now = tv_currently_idle();
      $idle_begin = time() if $idle_now && !defined($idle_begin);
      $TV_IS_IDLE = $idle_now && $idle_begin &&
                    (time() - $idle_begin) > $MAX_IDLE_SECONDS;

      while (@queued_fetch) {
        $TV->clear() if $idle_warning_shown;
        undef $idle_begin;
        undef $idle_warning_shown;
        update_status($TV, shift(@queued_fetch), \$last_msg, $slept, \$countup);
      }

      if (@queued_playback) {
        $TV->clear() if $idle_warning_shown;
        undef $idle_begin;
        undef $idle_warning_shown;
        my @copy = map(xlog_hash($_), @queued_playback);
        tv_show_playlist($TV, \@copy, $last_game);
        sleep 4 if $slept == 0;
        last;
      }

      ++$slept if $countup;
      next RELOOP if $last_msg && $slept - $last_msg > 20;

      if (!$last_msg && $idle_now && $idle_begin && $file_queue) {
        my $idle_for = time() - $idle_begin;
        my $will_exit = $MAX_IDLE_SECONDS - $idle_for;
        if ($idle_for > 7) {
          $will_exit = $will_exit <= 0 ? 'now' : "in ${will_exit}s";
          $TV->at(23)->color(qw/dim white/);
          $TV->write("Channel is idle, will exit $will_exit");
          $TV->clear_to_eol();
          $idle_warning_shown = 1;
        }
      }

      sleep 1;
    }

    my $line = shift(@queued_playback);
    if ($line) {
      my $g = xlog_hash($line);
      warn "Playing ttyrec for ", desc_game($g), " for $TERMCAST_CHANNEL\n";
      eval {
        $TV->play_game($g);
      };

      my $err = $@;
      warn "Completed playback for ", desc_game($g), " for $TERMCAST_CHANNEL. Error: $err\n";
      if ($err) {
        $TV->clear();
        $TV->write("\e[1;31mPlayback failed for: \e[0m\r\n",
                   desc_game_brief($g), ": $err\r\n");
        undef $last_game;
      } else {
        $last_game = $g;
      }
    }
  }
}

request_tv();
