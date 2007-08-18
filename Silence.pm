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
	return 1 if $srv =~ /^defender.*\..*\./;
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
	}, KILL => check => sub {
		my $act = shift;
		my($src,$nick,$net) = @$act{qw(src dst net)};
		return undef unless $src && $src->isa('Nick');
		return undef unless service $src;
		return undef unless $nick->homenick() eq $nick->str($net);
		&Janus::append(+{
			type => 'RECONNECT',
			src => $src,
			dst => $nick,
			net => $net,
			killed => 1,
		});
		1;
	},
);

1;
