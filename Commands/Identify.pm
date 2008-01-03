# Copyright (C) 2007 Nima Gardideh
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Commands::Identify;
use strict;
use warnings;
our($VERSION) = '$Rev$' =~ /(\d+)/;

&Janus::command_add({
	cmd => 'forceid',
	help => 'Forcibly tries to identify a ClientBot with whatever method possible.',
	details => [
		"Syntax: \002FORCEID\002 network",
		"Tries to identify to the network with a method mentioned in the config, serever has to be a ClientBot",
	],
	acl => 1,
	code => sub {
		my $nick = shift;
		my $net = $Janus::nets{lc $_} || $Janus::ijnets{lc $_};
		return unless $net;
		return &Janus::jmsg($nick, "Network needs to be a ClientBot.") unless $net->isa('Server::ClientBot');
		my ($user,$pass);
		if ($net->param('nspass') || $net->param('qauth')) {
			&Janus::jmsg($nick, "Done.");
		} else {			
			&Janus::jmsg($nick, "Network " + lc $_ + " had no identity method configured.");
		}
		# Send the IDENTIFY anyway, in case additional methods are added without our knowledge
		&Janus::insert_full(+{
			type => 'IDENTIFY',
			dst => $net,
		});	
	},
});

1;
