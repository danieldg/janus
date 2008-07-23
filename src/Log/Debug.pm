# Copyright (C) 2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Log::Debug;
use strict;
use warnings;

our $INST;
$INST ||= do { my $i; bless \$i; };

sub new { $INST }

sub log {
	print "\e[$Log::ANSI[$_[1]]m$_[2]: $_[3]\e[m\n";
}

1;
