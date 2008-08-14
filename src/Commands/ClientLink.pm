# Copyright (C) 2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::ClientLink;
use strict;
use warnings;

&Janus::command_add({
	cmd => 'clink',
	help => 'Requests a link from a clientbot network',
	details => [
		"\002CLINK\002 cb-net #channel [dest-net] [#dest-chan]"
	],
	acl => 1,
	code => sub {
		my($nick,$args) = @_;
		unless ($args && $args =~ /^(\S+) +(#\S*)(?: +([^# ]+)(?: +(#\S*))?)?$/) {
			return &Janus::jmsg($nick, 'Invalid syntax');
		}
		my($bnet, $bchan, $dnet, $dchan) = ($1,$2,$3,$4);
		$dnet ||= $nick->homenet()->name();
		$dchan ||= $bchan;
		my $cb = $Janus::nets{$bnet}  or return &Interface::jmsg($nick, 'Client network not found');
		$cb->isa('Server::ClientBot') or return &Interface::jmsg($nick, 'Client network must be a clientbot');
		my $dn = $Janus::nets{$dnet}  or return &Interface::jmsg($nick, 'Destination network not found');
		$Link::request{$dnet}{$dchan}{mode} or return &Interface::jmsg($nick, 'Channel must be shared');
		&Janus::append(+{
			type => 'LINKREQ',
			src => $nick,
			chan => $cb->chan($bchan, 1),
			dst => $dn,
			dlink => $dchan,
			reqby => $nick->realhostmask(),
			reqtime => $Janus::time,
		});
	}
});

1;
