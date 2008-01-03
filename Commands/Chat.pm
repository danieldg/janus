# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Commands::Chat;
use strict;
use warnings;
our($VERSION) = '$Rev$' =~ /(\d+)/;

&Janus::command_add({
	cmd => 'chatto',
	help => 'Send a message to all opers on a specific network',
	details => [
		"Syntax: \002CHATTO\002 network|* message",
		'Note: The command /chatops, if available, is relayed to all networks',
	],
	acl => 1,
	code => sub {
		my($nick,$msg) = @_;
		$msg =~ s/^(\S+) // or return;
		my $net = $Janus::nets{$1};
		return unless $net || $1 eq '*';
		&Janus::append(+{
			type => 'CHATOPS',
			src => $nick,
			msg => $msg,
			sendto => ($1 eq '*' ? $Janus::server : [ $net ]),
		});
	},
});

1;
