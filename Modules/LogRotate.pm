# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Modules::LogRotate;
use strict;
use warnings;

our($VERSION) = '$Rev$' =~ /(\d+)/;

my $log = 'log/'.time;
umask 022;
open STDOUT, '>', $log or die $!;
open STDERR, '>&', \*STDOUT or die $!;

1;
