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
	api => '=src =replyto act net $ @',
	code => sub {
		my($src,$dst, $ract, $cb, $bchan, $dnet, $dchan) = @_;
		if ($cb->jlink) {
			my %act = %$ract;
			$act{dst} = $cb->jlink;
			&Event::append(\%act);
			return;
		}

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
}, {
	cmd => 'clinkrm',
	help => 'Removes a clientbot channel link',
	section => 'Channel',
	details => [
		"\002CLINKRM\002 cb-net #channel"
	],
	acl => 'clink',
	api => '=src =replyto act net $',
	code => sub {
		my($src,$dst, $ract, $cb, $bchan) = @_;

		if ($cb->jlink) {
			my %act = %$ract;
			$act{dst} = $cb->jlink;
			&Event::append(\%act);
			return;
		}

		$cb->isa('Server::ClientBot') or return &Interface::jmsg($dst, 'Source network must be a clientbot');
		my $req = delete $Link::request{$cb->name}{lc $bchan};
		if ($req) {
			&Log::audit("Channel $bchan on ".$cb->name." delinked from $req->{chan} on $req->{net} by ".$src->netnick);
			&Janus::jmsg($dst, 'Done');
		} else {
			&Janus::jmsg($dst, 'Not found');
		}
	},
});

1;
