# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Commands::Chat;
use strict;
use warnings;
our($VERSION) = '$Rev$' =~ /(\d+)/;

&Janus::command_add({
	cmd => 'chatops',
	help => 'Send a messge to opers on all other networks',
	details => [
		"Syntax: \002CHATOPS\002 message",
		'The command /chatops, if available, can also be relayed',
	],
	code => sub {
		my($nick,$msg) = @_;
		return &Janus::jmsg($nick, "You must be an IRC operator to use this command") unless $nick->has_mode('oper');
		&Janus::append(+{
			type => 'CHATOPS',
			src => $nick,
			sendto => [ values %Janus::nets ],
			msg => $msg,
		});
	},
}, {
	cmd => 'chatto',
	help => 'Send a message to all opers on a specific network',
	details => [
		"Syntax: \002CHATTO\002 network message",
	],
	code => sub {
		my($nick,$msg) = @_;
		return &Janus::jmsg($nick, "You must be an IRC operator to use this command") unless $nick->has_mode('oper');
		$msg =~ s/^(\S+) // or return;
		my $net = $Janus::nets{$1} or return;
		&Janus::append(+{
			type => 'CHATOPS',
			src => $nick,
			dst => $net,
			msg => $msg,
		});
	},
});

1;
