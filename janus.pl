#!/usr/bin/perl
# Copyright (C) 2007-2008 Daniel De Graaf
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
use POSIX 'setsid';

our $VERSION = '1.12';

if ($^P) {
	# $^P is nonzero if run inside perl -d
	require Log::Debug;
	no warnings 'once';
	@Log::listeners = $Log::Debug::INST;
	&Log::dump_queue();
} else {
	open STDIN, '/dev/null' or die $!;
	if (-t STDOUT) {
		open STDOUT, '>daemon.log' or die $!;
		open STDERR, '>&', \*STDOUT or die $!;
	}
	my $pid = fork;
	die $! unless defined $pid;
	if ($pid) {
		if ($ARGV[0] && $ARGV[0] =~ /^-.*p/) {
			open P, '>janus.pid' or die $!;
			print P $pid,"\n";
			close P;
		}
		exit;
	}
	setsid;
}

$| = 1;
$SIG{PIPE} = 'IGNORE';
$SIG{CHLD} = 'IGNORE';

&Janus::load('Conffile') or die;
&Janus::insert_full(+{ type => 'INITCONF', (@ARGV ? (file => $ARGV[0]) : ()) });
&Janus::load('Connection') or die;
&Janus::insert_full(+{ type => 'INIT', args => \@ARGV });
&Janus::insert_full(+{ type => 'RUN' });

eval { 
	1 while &Connection::timestep();
	1;
} ? &Debug::info("Goodbye!\n") : &Debug::err("Aborting, error=$@");
