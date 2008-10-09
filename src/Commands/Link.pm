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
	code => sub {
		my($src,$dst,$cname1, $nname2, $cname2) = @_;

		if ($src->jlink) {
			return &Janus::jmsg($dst, 'Please execute this command on your own server');
		}
		$cname2 ||= $cname1;
		unless ($nname2) {
			&Janus::jmsg($dst, 'Usage: LINK localchan network [remotechan]');
			return;
		}

		my $net1 = $src->homenet;
		my $net2 = $Janus::nets{lc $nname2} or do {
			&Janus::jmsg($dst, "Cannot find network $nname2");
			return;
		};
		my $chan1 = $net1->chan(lc $cname1,0) or do {
			&Janus::jmsg($dst, "Cannot find channel $cname1");
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
	}
}, {
	cmd => 'create',
	help => 'Creates a channel that other networks can link to',
	section => 'Channel',
	details => [
		"Syntax: \002CREATE\002 #channel"
	],
	code => sub {
		my($src,$dst,$cname) = @_;

		my $net = $src->homenet;

		if ($net->jlink()) {
			return &Janus::jmsg($dst, 'Please execute this command on your own server');
		}

		my $chan = $cname && $net->chan($cname, 0);
		unless ($chan) {
			&Janus::jmsg($dst, $cname ? 'Cannot find that channel' : 'Syntax: CREATE #channel');
			return;
		}
		return unless &Account::chan_access_chk($src, $chan, 'create', $dst);
		if (1 < scalar $chan->nets) {
			&Janus::jmsg($dst, 'That channel is already linked');
			return;
		}
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
	code => sub {
		my($src,$dst, $cname, $nname) = @_;
		my $snet = $src->homenet;
		my $chan = $snet->chan($cname) or do {
			&Janus::jmsg($dst, "Cannot find channel $cname");
			return;
		};
		return unless &Account::chan_access_chk($src, $chan, 'link', $dst);
		if ($snet == $chan->homenet() && 1 < scalar $chan->nets()) {
			unless ($nname) {
				&Janus::jmsg($dst, 'Please specify the network to delink, or use DESTROY');
				return;
			}
			$snet = $Janus::nets{$nname};
			unless ($snet) {
				&Janus::jmsg($dst, 'Could not find that network');
				return;
			}
		} elsif ($nname) {
			&Janus::jmsg($dst, 'You cannot specify the network to delink');
			return;
		}

		&Log::audit("Channel $cname delinked from $nname by ".$src->netnick);
		&Janus::append(+{
			type => 'DELINK',
			src => $src,
			dst => $chan,
			net => $snet,
		});
	},
}, {
	cmd => 'destroy',
	help => 'Removes a channel that other networks can link to',
	section => 'Channel',
	details => [
		"Syntax: \002DESTROY\002 #channel",
	],
	code => sub {
		my($src,$dst,$cname) = @_;

		my $net = $src->homenet();

		if ($net->jlink()) {
			return &Janus::jmsg($dst, 'Please execute this command on your own server');
		}

		my $chan = $cname && $net->chan($cname, 0);
		unless ($chan) {
			&Janus::jmsg($dst, $cname ? 'Cannot find that channel' : 'Syntax: DESTROY #channel');
			return;
		}
		return unless &Account::chan_access_chk($src, $chan, 'create', $dst);
		&Log::audit("Channel $cname destroyed by ".$src->netnick);
		&Janus::append(+{
			type => 'DELINK',
			src => $src,
			dst => $chan,
			net => $net,
			sendto => $Janus::global,
		});
	},
});

1;
