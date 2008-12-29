#! /usr/bin/perl

use strict;
use warnings;

use CSplat::DB;
use CSplat::Seek;
use CSplat::Select;
use CSplat::Xlog;

use Getopt::Long;

my %opt;
GetOptions(\%opt, 'filter=s');

die "No filter specified\n" unless $opt{filter};

CSplat::DB::open_db();

my @games = CSplat::DB::fetch_all_games(splat => '*');
my $xlfil = CSplat::Xlog::xlog_line($opt{filter});

@games = grep(CSplat::Select::filter_matches($xlfil, $_), @games);

die "No games match filter\n" unless @games;

my $game = $games[0];
print "Examining ", CSplat::Xlog::desc_game($game), "\n";

CSplat::DB::tty_delete_frame_offset($game);
CSplat::Seek::tty_frame_offset($game, 1);
