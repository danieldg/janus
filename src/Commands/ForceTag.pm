# Copyright (C) 2008-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::ForceTag;
use strict;
use warnings;

Event::command_add({
	cmd => 'forcetag',
	help => 'Forces a user to use a tagged nick on a network',
	section => 'Network',
	details => [
		"Syntax: \002FORCETAG\002 nick [network]",
	],
	acl => 'forcetag',
	api => '=src =replyto nick localdefnet',
	code => sub {
		my ($src,$dst,$nick,$net) = @_;
		return Janus::jmsg($dst, 'Not on that network') unless $nick->is_on($net);
		Event::append({
			type => 'RECONNECT',
			src => $src,
			dst => $nick,
			net => $net,
			killed => 0,
			altnick => 1,
		});
		Janus::jmsg($dst, 'Done');
	},
});

1;
