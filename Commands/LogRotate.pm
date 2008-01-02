# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Commands::LogRotate;
use strict;
use warnings;
use POSIX qw(strftime);

our($VERSION) = '$Rev$' =~ /(\d+)/;

&Janus::command_add({
	cmd => 'logrotate',
	help => 'Opens a new debug logfile so that logs do not grow too large',
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
