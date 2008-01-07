# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::LogRotate;
use strict;
use warnings;
use POSIX qw(strftime);

our($VERSION) = '$Rev$' =~ /(\d+)/;

&Janus::command_add({
	cmd => 'logrotate',
	help => 'Opens a new debug logfile so that logs do not grow too large',
	acl => 1,
	code => sub {
		my $log = 'log/';
		my $fmt = $Conffile::netconf{set}{datefmt};
		if ($fmt) {
			$log .= strftime $fmt, gmtime;
		} else {
			$log .= time;
		}

		umask 022;
		open STDOUT, '>', $log or die $!;
		open STDERR, '>&', \*STDOUT or die $!;
	}
});

1;
