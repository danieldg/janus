# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Modules::LogRotate;
use strict;
use warnings;

our($VERSION) = '$Rev$' =~ /(\d+)/;

my $log = 'log/';
my $fmt = $Conffile::netconf{janus}{datefmt};
if ($fmt) {
	use POSIX qw(strftime);
	$log .= strftime $fmt, gmtime;
} else {
	$log .= time;
}

umask 022;
open STDOUT, '>', $log or die $!;
open STDERR, '>&', \*STDOUT or die $!;

1;
