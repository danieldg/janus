# Copyright (C) 2008-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Log::Base;
use strict;
use warnings;
use integer;
use Persist;

our(@name, @filter);
&Persist::register_vars(qw(name filter));
&Persist::autoinit(qw(name filter));
&Persist::autoget(qw(name));

sub _init {
	my $log = shift;
	$filter[$$log] ||= '*';
	$name[$$log];
}

sub log {
	my($log, $lvl) = (shift,shift);
	for (split /\s+/, $filter[$$log]) {
		if ($_ eq '*' || $lvl eq $_) {
			return $log->output(@_);
		}
	}
}

sub reconfigure {
	my($log,$conf) = @_;
	$filter[$$log] = $conf->{filter} || '*';
}

1
