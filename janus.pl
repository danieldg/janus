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

our $VERSION = '1.12';

if ($^P) {
	# $^P is nonzero if run inside perl -d
	require Log::Debug;
	no warnings 'once';
	@Log::listeners = $Log::Debug::INST;
	&Log::dump_queue();
}

$| = 1;
$SIG{PIPE} = 'IGNORE';
$SIG{CHLD} = 'IGNORE';

&Janus::load('Conffile') or die;
&Event::insert_full(+{ type => 'INITCONF', (@ARGV ? (file => $ARGV[0]) : ()) });
unless (%Conffile::netconf) {
	print "Could not start:\n";
	require Log::Debug;
	no warnings 'once';
	@Log::listeners = $Log::Debug::INST;
	&Log::dump_queue();
	exit 1;
}

unless ($^P || $Conffile::netconf{set}{nofork}) {
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
	require POSIX;
	POSIX::setsid;
}

&Log::timestamp($Janus::time);
&Janus::load('Connection') or die;
&Event::insert_full(+{ type => 'INIT', args => \@ARGV });
&Event::insert_full(+{ type => 'RUN' });

eval { 
	&Connection::ts_simple while 1;
};
&Log::err("Aborting, error=$@");
