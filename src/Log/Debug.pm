# Copyright (C) 2008-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Log::Debug;
use strict;
use warnings;

our $INST;
$INST ||= do { my $i; bless \$i; };

sub new { $INST }
sub name { 'Debug' }

sub log {
	print "\e[$Log::ANSI[$_[2]]m$_[3]: $_[4]\e[m\n";
}

1;
