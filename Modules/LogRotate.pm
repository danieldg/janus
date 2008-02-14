# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Modules::LogRotate;
use strict;
use warnings;
use POSIX qw(strftime);

our $event;

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
}

unless ($event) {
	$event = {
		repeat => 86400,
		code => sub {
			my $s = shift;
			return unless $s->{repeat};
			rotate;
		}
	};
	&Janus::schedule($event);
}

&Janus::hook_add('INIT' => act => \&rotate);

1;
