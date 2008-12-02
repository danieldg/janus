# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::Link;
use strict;
use warnings;

&Event::command_add({
	cmd => 'link',
	help => 'Link to a remote network\'s shared channel',
	section => 'Channel',
	details => [ 
		"Syntax: \002LINK\002 channel network [remotechan]",
		"The remote network must use the \002CREATE\002 command to",
		"share a channel before links to that channel will be accepted",
	],
	api => '=src =replyto localchan net ?$',
	code => sub {
		my($src,$dst,$chan1,$net2,$cname2) = @_;

		return unless &Account::chan_access_chk($src, $chan1, 'link', $dst);

		my $net1 = $chan1->homenet;
		my $cname1 = $chan1->homename;
		$cname2 ||= $cname1;

		if ($Link::request{$net1->name()}{lc $cname1}{mode}) {
			&Janus::jmsg($dst, 'This network is the owner for that channel. Other networks must link to it.');
			return;
		}
		if (1 < scalar $chan1->nets()) {
			&Janus::jmsg($dst, 'That channel is already linked');
			return;
		}
		&Event::append(+{
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
	api => '=src =replyto localchan',
	code => sub {
		my($src,$dst,$chan) = @_;
		my $net = $chan->homenet;

		if (1 < scalar $chan->nets) {
			&Janus::jmsg($dst, 'That channel is already linked');
			return;
		}
		return unless &Account::chan_access_chk($src, $chan, 'create', $dst);
		my $cname = $chan->str($net);
		&Log::audit("New channel $cname shared by ".$src->netnick);
		&Event::append(+{
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
	api => '=src =replyto localchan ?net ?$',
	code => sub {
		my($src, $dst, $chan, $net, $cause) = @_;
		return unless &Account::chan_access_chk($src, $chan, 'delink', $dst);
		$net ||= $src->homenet;
		if ($net == $chan->homenet) {
			&Janus::jmsg($dst, 'Please specify the network to delink, or use DESTROY');
			return;
		}
		if ($src->homenet == $chan->homenet) {
			$cause = 'reject';
		} elsif ($src->homenet == $net) {
			$cause = 'unlink';
		} else {
			return unless &Account::chan_access_chk($src, $chan, 'create', $dst);
			$cause = 'split' unless $cause eq 'reject' || $cause eq 'unlink';
		}

		&Log::audit('Channel '.$chan->netname.' delinked from '.$net->name.' by '.$src->netnick);
		&Event::append(+{
			type => 'DELINK',
			cause => $cause,
			src => $src,
			dst => $chan,
			net => $net,
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
	api => '=src =replyto localchan',
	code => sub {
		my($src,$dst,$chan) = @_;
		my $net = $chan->homenet;
		return unless &Account::chan_access_chk($src, $chan, 'create', $dst);
		&Log::audit('Channel '.$chan->netname.' destroyed by '.$src->netnick);
		&Event::append(+{
			type => 'DELINK',
			cause => 'destroy',
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
