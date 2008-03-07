# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::Time;
use strict;
use warnings;

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
			msg => "Janus server time: ".$Janus::time,
		}, {
			type => 'TSREPORT',
			src => $nick,
			sendto => [ $nick->netlist() ],
			except => $nick->homenet(),
		});
	},
});

1;
