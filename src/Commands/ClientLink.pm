# Copyright (C) 2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::ClientLink;
use strict;
use warnings;

&Event::command_add({
	cmd => 'clink',
	help => 'Requests a link from a clientbot network',
	section => 'Channel',
	details => [
		"\002CLINK\002 cb-net #channel [dest-net] [#dest-chan]"
	],
	acl => 'clink',
	api => '=src =replyto localnet $ ?$ ?$',
	code => sub {
		my($src,$dst, $cb, $bchan, $dnet, $dchan) = @_;

		if ($dnet && $dnet =~ /#/) {
			$dchan = $dnet;
			$dnet = $src->homenet->name;
		} else {
			$dnet ||= $src->homenet->name;
			$dchan ||= $bchan;
		}
		$bchan = lc $bchan;
		$dchan = lc $dchan;
		$cb->isa('Server::ClientBot') or return &Interface::jmsg($dst, 'Source network must be a clientbot');
		my $dn = $Janus::nets{$dnet}  or return &Interface::jmsg($dst, 'Destination network not found');
		$Link::request{$dnet}{$dchan} or return &Interface::jmsg($dst, 'Channel must be shared');
		$Link::request{$dnet}{$dchan}{mode} or return &Interface::jmsg($dst, 'Channel must be shared');
		&Log::audit("Channel $bchan on ".$cb->name." linked to $dchan on $dnet by ".$src->netnick);
		&Event::append(+{
			type => 'LINKREQ',
			src => $src,
			chan => $cb->chan($bchan, 1),
			dst => $dn,
			dlink => $dchan,
			reqby => $src->realhostmask(),
			reqtime => $Janus::time,
		});
	}
}, {
	cmd => 'clinkrm',
	help => 'Removes a clientbot channel link',
	section => 'Channel',
	details => [
		"\002CLINKRM\002 cb-net #channel"
	],
	acl => 'clink',
	api => '=src =replyto localnet $',
	code => sub {
		my($src,$dst, $cb, $bchan) = @_;

		$cb->isa('Server::ClientBot') or return &Interface::jmsg($dst, 'Source network must be a clientbot');
		my $req = delete $Link::request{$cb->name}{lc $bchan};
		my $chan = $cb->chan($bchan);
		if ($chan) {
			&Event::append(+{
				type => 'DELINK',
				cause => 'unlink',
				src => $src,
				dst => $chan,
				net => $cb,
			});
		}
		if ($req || $chan) {
			&Log::audit("Channel $bchan on ".$cb->name." delinked from $req->{chan} on $req->{net} by ".$src->netnick);
			&Janus::jmsg($dst, 'Done');
		} else {
			&Janus::jmsg($dst, 'Not found');
		}
	},
});

1;
