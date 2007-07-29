# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Bridge;
use Persist;
use strict;
use warnings;

__PERSIST__

__CODE__

&Janus::hook_add(
	NEWNICK => act => sub {
		my $act = shift;
		my $nick = $act->{dst};
		for my $net (values %Janus::nets) {
			next if $nick->homenet()->id() eq $net->id();
			&Janus::append({
				type => 'CONNECT',
				dst => $nick,
				net => $net,
			});
		}
	},			
);

1;
