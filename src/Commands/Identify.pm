# Copyright (C) 2007-2008 Nima Gardideh
# Released under the GNU Affero General Public License v3
package Commands::Identify;
use strict;
use warnings;

&Janus::command_add({
	cmd => 'forceid',
	help => 'Forcibly tries to identify a ClientBot with whatever method possible.',
	details => [
		"Syntax: \002FORCEID\002 network [pass]",
		'Tries to identify to the network with a method mentioned in the config, serever has to be a ClientBot.',
		'If supported with a password than it will identify with the specified password (all known formats supported)',
		"To identify to NickServ, use: 	\002FORCEID\002 network [password]",
		"To identify to Q(uakeNet)use: 	\002FORCEID\002 network [user] [password]",
	],
	acl => 1,
	code => sub {
		my ($nick,$args) = @_;
		my ($nname, $auth) = $args =~ /(\S+)\s*(.*)/ or return;
		my $net = $Janus::nets{lc $nname} or return;
		return &Janus::jmsg($nick, "Network needs to be a ClientBot linked server.") unless $net->isa('Server::ClientBot');
		if ($net->param('nspass') || $net->param('qauth')) {
			&Janus::jmsg($nick, "Done.");
		} elsif (length $auth < 4) { # a NickServ pass is obviously longer than 4 :)
			&Janus::jmsg($nick, "Network " + lc $_ + " had no identity method configured.");
		}
		if ($auth =~ /(\S+)\s+(\S+)/) {
			&Janus::append(+{
				type => 'IDENTIFY',
				user => $1,
				pass => $2,
				dst => $net,
			});
		} else {
			&Janus::append(+{
				type => 'IDENTIFY',
				pass => $auth,
				dst => $net,
			});
		}
	},
});

1;
