# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Modules::Signals;
use strict;
use warnings;

our($VERSION) = '$Rev$' =~ /(\d+)/;

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
