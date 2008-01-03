# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Commands::Time;
use strict;
use warnings;
our($VERSION) = '$Rev$' =~ /(\d+)/;

&Janus::command_add({
	cmd => 'alltime',
	help => 'Get a time report from all janus servers',
	acl => 1,
	code => sub {
		my($nick,$msg) = @_;
		&Janus::append(+{
			type => 'MSG',
			src => $nick->homenet(),
			dst => $nick,
			msgtype => 'NOTICE',
			msg => "Janus server time: ".time,
		}, {
			type => 'TSREPORT',
			src => $nick,
			sendto => [ $nick->netlist() ],
			except => $nick->homenet(),
		});
	},
});

1;
