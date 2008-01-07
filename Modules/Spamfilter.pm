# Copyright (C) 2007 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Modules::Spamfilter;
use strict;
use warnings;

our($VERSION) = '$Rev$' =~ /(\d+)/;

&Janus::hook_add(
	MSG => check => sub {
		my $act = shift;
		# FIXME this is 100% a temporary hack
		if ($act->{msg} =~ /spam spam spam expression/) {
			my $spammer = $act->{src};
			my $snet = $spammer->homenet();
			&Janus::append(+{
				type => 'KILL',
				net => $snet,
				src => $snet,
				dst => $spammer,
				msg => 'Spam',
			});
			return 1;
		}
		undef;
	},
);

1;
