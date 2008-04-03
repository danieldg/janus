# Copyright (C) 2007 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Modules::Signals;
use strict;
use warnings;

$SIG{HUP} = sub {
	&Janus::schedule({
		code => sub {
			&Janus::insert_full({
				type => 'REHASH',
			});
		},
		delay => 0,
	});
};

1;
