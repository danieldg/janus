# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Modules::LogRotate;
use strict;
use warnings;
use POSIX qw(strftime);

our $event;
our $logname;

sub rotate {
	my $log = 'log/';
	my $fmt = $Conffile::netconf{set}{datefmt};
	if ($fmt) {
		$log .= strftime $fmt, gmtime $Janus::time;
	} else {
		$log .= $Janus::time;
	}

	umask 022;
	open STDOUT, '>', $log or die $!;
	open STDERR, '>&', \*STDOUT or die $!;

	if ($logname && -f $logname && $Conffile::netconf{set}{oldlog}) {
		fork or do {
			{ exec $Conffile::netconf{set}{oldlog}, $logname; }
			POSIX::_exit(1);
		};
	}
	$logname = $log;
}

unless ($event) {
	my $time = $Conffile::netconf{set}{logrotate} || 86400;
	$event = {
		repeat => $time,
		code => sub {
			my $s = shift;
			return unless $s->{repeat};
			rotate;
		}
	};
	&Janus::schedule($event);
	rotate;
}


1;
