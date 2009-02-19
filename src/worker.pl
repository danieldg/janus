#!/usr/bin/perl
# Copyright (C) 2007-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
use strict;
use warnings;
BEGIN {
	# Support for taint mode: we don't acually need most of these protections
	# as the person running janus.pl is assumed to have shell access anyway.
	# The real benefit of taint mode is protecting IRC-sourced data
	$_ = $ENV{PATH};
	s/:.(:|$)/$1/;
	s/~/$ENV{HOME}/g;
	/(.*)/;
	$ENV{PATH} = $1;
	$ENV{SHELL} = '/bin/sh';
	delete @ENV{'IFS', 'CDPATH', 'ENV', 'BASH_ENV'};
	do './src/Janus.pm' or die $@;
}

our $VERSION = '1.14';

# control socket on stdin, needs to be read/write
open $Multiplex::sock, '+>&=0';
select $Multiplex::sock; $| = 1;
select STDOUT; $| = 1;

$SIG{PIPE} = 'IGNORE';
$SIG{CHLD} = 'IGNORE';

if ($^P) {
	# $^P is nonzero if run inside perl -d
	require Log::Debug;
	no warnings 'once';
	@Log::listeners = $Log::Debug::INST;
	Log::dump_queue();
}

$Conffile::conffile = $ARGV[0];

my $line = <$Multiplex::sock>;
chomp $line;
if ($line =~ /^BOOT (\d+)/) {
	no warnings 'once';
	$Multiplex::master_api = $1;
	require Conffile;
	Conffile::read_conf();
	Log::timestamp($Janus::time);
	require Multiplex;
	Event::insert_full(+{ type => 'INIT' });
	Event::insert_full(+{ type => 'RUN' });
} elsif ($line =~ /^R\S* (\S+)$/) {
	my $file = $1;
	require Snapshot;
	Snapshot::restore_from($file);
} else {
	die "Bad line from control socket: $line";
}

&Multiplex::timestep while 1;
