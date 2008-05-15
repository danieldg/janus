# Copyright (C) 2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::ClientLink;
use strict;
use warnings;

&Janus::command_add({
	cmd => 'clink',
	help => 'Requests a link from a clientbot network',
	details => [
		"\002CLINK\002 cb-net #channel [dest-net]"
	],
	acl => 1,
	code => sub {
		my($nick,$args) = @_;
		$args ||= '';
		return &Janus::jmsg($nick, 'Invalid syntax') unless $args =~ /^(\S+) (#\S*)(?: (\S+))?/;
		my($bname, $cname, $nname) = ($1,$2,$3);
		$nname ||= $nick->homenet()->name();
		my $cb = $Janus::nets{$bname} or return &Interface::jmsg($nick, 'Client network not found');
		$cb->isa('Server::ClientBot') or return &Interface::jmsg($nick, 'Client network must be a clientbot');
		my $dn = $Janus::nets{$nname} or return &Interface::jmsg($nick, 'Destination network not found');
		&Janus::append(+{
			type => 'LINKREQ',
			src => $nick,
			dst => $dn,
			net => $cb,
			slink => $cname,
			dlink => $cname,
			reqby => $nick->realhostmask(),
			reqtime => $Janus::time,
		});
	}
});

1;
