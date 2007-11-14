# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
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
				src => $Janus::interface,
				dst => $spammer,
				msg => 'Spam',
			});
			return 1;
		}
		undef;
	},
);

1;
