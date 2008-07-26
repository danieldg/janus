# Copyright (C) 2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Log::Base;
use strict;
use warnings;
use integer;
use Persist;

our(@filter);
&Persist::register_vars(qw(filter));
&Persist::autoinit(qw(filter));

sub _init {
	my $log = shift;
	$filter[$$log] ||= '*';
	();
}

sub log {
	my($log, $lvl) = (shift,shift);
	for (split /\s*/, $filter[$$log]) {
		if ($_ eq '*' || $lvl =~ /^$_$/) {
			return $log->output(@_);
		}
	}
}

1
