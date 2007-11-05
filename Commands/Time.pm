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
	code => sub {
		my($nick,$msg) = @_;
		return &Janus::jmsg($nick, "You must be an IRC operator to use this command") unless $nick->has_mode('oper');
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
