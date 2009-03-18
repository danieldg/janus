# Copyright (C) 2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Util::Exec;
use strict;
use warnings;
use POSIX ':sys_wait_h';

$SIG{CHLD} = 'DEFAULT';

our %pid2cmd;
our $event;

sub waiter {
	my $pid = waitpid -1, WNOHANG;
	my $evt = delete $pid2cmd{$pid} or return;
	$evt->{code}->($evt) if $evt->{code};
	unless (%pid2cmd) {
		$event->{repeat} = 0;
		$event = undef;
	}
}

$event->{code} = \&waiter if $event;

sub reap {
	my($pid, $act) = @_;
	$act ||= {};
	$pid2cmd{$pid} = $act;
	unless ($event) {
		$event = {
			code => \&waiter,
			repeat => 1,
			desc => 'waitpid',
		};
		Event::schedule($event);
	}
}

sub system {
	my($cmd, $act) = @_;
	my $pid = fork;
	if ($pid) {
		reap $pid, $act;
		1;
	} elsif (defined $pid) {
		do { exec $cmd; };
		POSIX::_exit(1);
	} else {
		Log::err("Cannot fork: $!") if !defined $pid;
		0;
	}
}

sub bgrun {
	my($code, $act) = @_;
	my $pid = fork;
	if ($pid) {
		reap $pid, $act;
		1;
	} elsif (defined $pid) {
		my $rv = $code->($act);
		POSIX::_exit($rv);
	} else {
		Log::err("Cannot fork: $!") if !defined $pid;
		0;
	}
}

1;
