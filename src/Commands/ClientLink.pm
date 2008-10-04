# Copyright (C) 2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::ClientLink;
use strict;
use warnings;

&Janus::command_add({
	cmd => 'clink',
	help => 'Requests a link from a clientbot network',
	section => 'Channel',
	details => [
		"\002CLINK\002 cb-net #channel [dest-net] [#dest-chan]"
	],
	acl => 'clink',
	code => sub {
		my($src,$dst, $bnet, $bchan, $dnet, $dchan) = @_;
		if ($dnet && $dnet =~ /#/) {
			$dchan = $dnet;
			$dnet = $src->homenet->name;
		} else {
			$dnet ||= $src->homenet->name;
			$dchan ||= $bchan;
		}
		my $cb = $Janus::nets{$bnet}  or return &Interface::jmsg($dst, 'Client network not found');
		$cb->isa('Server::ClientBot') or return &Interface::jmsg($dst, 'Client network must be a clientbot');
		my $dn = $Janus::nets{$dnet}  or return &Interface::jmsg($dst, 'Destination network not found');
		$Link::request{$dnet}{$dchan}{mode} or return &Interface::jmsg($dst, 'Channel must be shared');
		&Log::audit("Channel $bchan on $bnet linked to $dchan on $dnet by ".$src->netnick);
		&Janus::append(+{
			type => 'LINKREQ',
			src => $src,
			chan => $cb->chan($bchan, 1),
			dst => $dn,
			dlink => $dchan,
			reqby => $src->realhostmask(),
			reqtime => $Janus::time,
		});
	}
});

1;
