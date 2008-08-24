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
		my($src,$dst,$msg) = @_;
		&Janus::append(+{
			type => 'MSG',
			src => $src->homenet,
			dst => $src,
			msgtype => 'NOTICE',
			msg => "Janus server time: ".$Janus::time,
		}, {
			type => 'TSREPORT',
			src => $src,
			sendto => [ $src->netlist() ],
			except => $src->homenet(),
		});
	},
});

1;
