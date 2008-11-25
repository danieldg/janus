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

my @flag = '-T';
$flag[0] = shift @ARGV if @ARGV && $ARGV[0] =~ /^-/;

if (!$^P && $flag[0] !~ /d/) {
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

sub start_child {
	my($cmd,$rcsock);
	socketpair $cmd, $rcsock, AF_UNIX, SOCK_STREAM, PF_UNSPEC;

	my $rc = fork;
	die $! unless defined $rc;

	if ($rc) {
		close $rcsock;
		$cmd->autoflush(1);
		@flag = () if $flag[0] eq '-T';
		return $cmd;
	} else {
		open STDIN, '+>&', $rcsock;
		close $cmd;
		close $rcsock;
		exec 'perl', @flag, 'src/worker.pl', @ARGV;
		exit 1;
	}
}

my $cmd = start_child;
print $cmd "BOOT 5\n";
do './src/Multiplex.pm' or die $@;
&Multiplex::run($cmd);
