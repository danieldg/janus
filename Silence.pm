# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Silence;
use Persist;
use strict;
use warnings;

our($VERSION) = '$Rev$' =~ /(\d+)/;

__PERSIST__
__CODE__

sub service {
	my $n = shift;
	my $srv = $n->info('home_server');
	return 0 unless $srv;
	return 0 if $srv =~ /^services\.qliner/;
	return 1 if $srv =~ /^stats\./;
	return 1 if $srv =~ /^service.*\..*\./;
}

&Janus::hook_add(
	MSG => check => sub {
		my $act = shift;
		my $src = $act->{src};
		my $dst = $act->{dst};
		return undef unless $src->isa('Nick') && $dst->isa('Nick');
		return 1 if service($src);
		return 1 if service($dst);
		undef;
	},
);

1;
