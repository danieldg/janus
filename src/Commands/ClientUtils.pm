# Copyright (C) 2007-2008 Nima Gardideh
# Copyright (C) 2007-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::ClientUtils;
use strict;
use warnings;

Event::command_add({
	cmd => 'botnick',
	help => 'Changes the nick of a ClientBot',
	section => 'Network',
	syntax => '<network> <newnick>',
	acl => 'botnick',
	api => '=replyto localnet $',
	code => sub {
		my($dst,$net,$nick) = @_;
		return Janus::jmsg($dst, "Network must be a ClientBot.") unless $net->isa('Server::ClientBot');
		$net->send("NICK $nick");
		Janus::jmsg($dst, 'Done');
	}
}, {
	cmd => 'forceid',
	help => 'Forcibly tries to identify a ClientBot to services',
	section => 'Network',
	syntax => '<network>',
	acl => 'forceid',
	api => '=replyto localnet',
	code => sub {
		my($dst, $net) = @_;
		return Janus::jmsg($dst, "Network must be a ClientBot.") unless $net->isa('Server::ClientBot');
		if ($net->param('nspass') || $net->param('qauth') || $net->param('x3acct')) {
			Janus::jmsg($dst, 'Done');
		} else {
			Janus::jmsg($dst, "Network has no identify method configured");
			return;
		}
		Event::append(+{
			type => 'IDENTIFY',
			dst => $net,
		});
	},
});

1;
