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

our $VERSION = '1.12';

if ($^P) {
	# $^P is nonzero if run inside perl -d
	print "Debug mode, log outputs to console\n";
	require Log::Debug;
	no warnings 'once';
	@Log::listeners = $Log::Debug::INST;
	Log::dump_queue();
}

$| = 1;
$SIG{PIPE} = 'IGNORE';
$SIG{CHLD} = 'IGNORE';

Janus::load('Conffile') and Event::insert_full(+{ type => 'INITCONF', (@ARGV ? (file => $ARGV[0]) : ()) });
unless (%Conffile::netconf) {
	print "Could not start:\n";
	require Log::Debug;
	no warnings 'once';
	@Log::listeners = $Log::Debug::INST;
	Log::dump_queue();
	exit 1;
}

my $runmode = $Conffile::netconf{set}{runmode};
$runmode = 'debug' if $^P;
unless ($runmode) {
	if (-x 'c-src/multiplex') {
		$runmode = 'mplex-daemon';
	} else {
		$runmode = 'uproc-daemon';
	}
	$runmode =~ s/-daemon// if $Conffile::netconf{set}{nofork};
}

if ($runmode =~ s/-daemon$//) {
	open STDIN, '/dev/null' or die $!;
	if (-t STDOUT) {
		open STDOUT, '>daemon.log' or die $!;
		open STDERR, '>&', \*STDOUT or die $!;
	}
	my $pid = fork;
	die $! unless defined $pid;
	if ($pid) {
		if ($Conffile::netconf{set}{pidfile}) {
			open P, '>', $Conffile::netconf{set}{pidfile} or die $!;
			print P $pid,"\n";
			close P;
		}
		exit 0;
	}
	require POSIX;
	POSIX::setsid;
}

if ($runmode eq 'mplex') {
	exec { './c-src/multiplex' } 'janus', @ARGV;
	exit 1;
}

if ($runmode ne 'uproc' && $runmode ne 'debug') {
	Log::warn('Invalid value for runmode in configuration');
}

Log::timestamp($Janus::time);
Janus::load('Connection') or die;
Event::insert_full(+{ type => 'INIT', args => \@ARGV });
Event::insert_full(+{ type => 'RUN' });

eval { 
	&Connection::ts_simple while 1;
};
Log::err("Aborting, error=$@");
