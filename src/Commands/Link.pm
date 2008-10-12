# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::Link;
use strict;
use warnings;

&Janus::command_add({
	cmd => 'link',
	help => 'Link to a remote network\'s shared channel',
	section => 'Channel',
	details => [ 
		"Syntax: \002LINK\002 channel network [remotechan]",
		"The remote network must use the \002CREATE\002 command to",
		"share a channel before links to that channel will be accepted",
	],
	api => '=src =replyto homenet $ net ?$',
	code => sub {
		my($src,$dst,$net1,$cname1,$net2,$cname2) = @_;

		if ($net1->jlink) {
			return &Janus::jmsg($dst, 'Please execute this command on your own server');
		}
		$cname2 ||= $cname1;

		my $chan1 = $net1->chan(lc $cname1,0) or do {
			&Janus::jmsg($dst, "Could not find channel $cname1");
			return;
		};

		return unless &Account::chan_access_chk($src, $chan1, 'link', $dst);

		if ($Link::request{$net1->name()}{lc $cname1}{mode}) {
			&Janus::jmsg($dst, 'This network is the owner for that channel. Other networks must link to it.');
			return;
		}
		if (1 < scalar $chan1->nets()) {
			&Janus::jmsg($dst, 'That channel is already linked');
			return;
		}
		&Janus::append(+{
			type => 'LINKREQ',
			src => $src,
			chan => $chan1,
			dst => $net2,
			dlink => lc $cname2,
			reqby => $src->realhostmask,
			reqtime => $Janus::time,
		});
		&Janus::jmsg($dst, 'Done');
	}
}, {
	cmd => 'create',
	help => 'Creates a channel that other networks can link to',
	section => 'Channel',
	details => [
		"Syntax: \002CREATE\002 #channel"
	],
	api => '=src homenet =replyto $',
	code => sub {
		my($src,$net,$dst,$cname) = @_;

		if ($net->jlink) {
			return &Janus::jmsg($dst, 'Please execute this command on your own server');
		}

		my $chan = $net->chan($cname, 0);
		unless ($chan) {
			&Janus::jmsg($dst, "Could not find channel $cname");
			return;
		}
		if (1 < scalar $chan->nets) {
			&Janus::jmsg($dst, 'That channel is already linked');
			return;
		}
		return unless &Account::chan_access_chk($src, $chan, 'create', $dst);
		&Log::audit("New channel $cname shared by ".$src->netnick);
		&Janus::append(+{
			type => 'LINKOFFER',
			src => $net,
			name => lc $cname,
			reqby => $src->realhostmask(),
			reqtime => $Janus::time,
		});
		&Janus::jmsg($dst, 'Done');
	},
}, {
	cmd => 'delink',
	help => 'Delinks a channel',
	section => 'Channel',
	details => [
		"Syntax: \002DELINK\002 #channel [network]",
		"The home newtwork must specify a network to delink, or use \002DESTROY\002",
		"Other networks can only delink themselves from the channel",
	],
	api => '=src homenet =replyto chan ?net',
	code => sub {
		my($src, $snet, $dst, $chan, $dnet) = @_;
		return unless &Account::chan_access_chk($src, $chan, 'link', $dst);
		if ($snet == $chan->homenet) {
			$snet = $dnet;
			unless ($dnet) {
				&Janus::jmsg($dst, 'Please specify the network to delink, or use DESTROY');
				return;
			}
		} elsif ($dnet) {
			&Janus::jmsg($dst, 'You cannot specify the network to delink');
			return;
		}

		&Log::audit('Channel '.$chan->homename.' delinked from '.$snet->name.' by '.$src->netnick);
		&Janus::append(+{
			type => 'DELINK',
			src => $src,
			dst => $chan,
			net => $snet,
		});
		&Janus::jmsg($dst, 'Done');
	},
}, {
	cmd => 'destroy',
	help => 'Removes a channel that other networks can link to',
	section => 'Channel',
	details => [
		"Syntax: \002DESTROY\002 #channel",
	],
	api => '=src homenet =replyto chan',
	code => sub {
		my($src,$net,$dst,$chan) = @_;

		if ($net->jlink()) {
			return &Janus::jmsg($dst, 'Please execute this command on your own server');
		}
		return unless &Account::chan_access_chk($src, $chan, 'create', $dst);
		&Log::audit('Channel '.$chan->homename.' destroyed by '.$src->netnick);
		&Janus::append(+{
			type => 'DELINK',
			src => $src,
			dst => $chan,
			net => $net,
		}, {
			type => 'LINKOFFER',
			src => $net,
			name => lc $chan->homename,
			remove => 1,
			reqby => $src->realhostmask(),
			reqtime => $Janus::time,
		});
		&Janus::jmsg($dst, 'Done');
	},
});

1;
