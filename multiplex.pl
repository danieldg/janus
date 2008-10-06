#!/usr/bin/perl
# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
use strict;
use warnings;
use Socket;
use IO::Handle;
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
}
use POSIX 'setsid';

our $VERSION = '1.12';

if (!$^P) {
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

my($cmd,$rcsock);
socketpair $cmd, $rcsock, AF_UNIX, SOCK_STREAM, PF_UNSPEC;
$cmd->autoflush(1);
$rcsock->autoflush(1);

my $rc = fork;
die $! unless defined $rc;

no warnings 'once';
if ($rc) {
	close $rcsock;
	my $line = <$cmd>;
	$Multiplex::ipv6 = ($line =~ /^1/);
	do './src/Multiplex.pm' or die $@;
	&Multiplex::run($cmd);
} else {
	close $cmd;
	$RemoteControl::sock = $rcsock;
	do './src/Janus.pm' or die $@;
	if ($^P) {
		# $^P is nonzero if run inside perl -d
		require Log::Debug;
		no warnings 'once';
		@Log::listeners = $Log::Debug::INST;
		&Log::dump_queue();
	}
	&Janus::load('Conffile') or die;
	&Janus::insert_full(+{ type => 'INITCONF', (@ARGV ? (file => $ARGV[0]) : ()) });
	&Log::timestamp($Janus::time);
	print $rcsock $Conffile::netconf{set}{ipv6} ? "1\n" : "0\n";
	&Janus::load('RemoteControl') or die;
	&Janus::insert_full(+{ type => 'INIT', args => \@ARGV });
	&Janus::insert_full(+{ type => 'RUN' });

	eval { 
		&RemoteControl::timestep while 1;
		1;
	} ? &Log::info("Goodbye!\n") : &Log::err("Aborting, error=$@");
}
