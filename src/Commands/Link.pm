# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::Link;
use strict;
use warnings;

&Janus::command_add({
	cmd => 'link',
	help => 'Links a channel with a remote network.',
	details => [ 
		"Syntax: \002LINK\002 channel network [remotechan]",
		"This command requires confirmation from the remote network before the link",
		"will be activated",
	],
	code => sub {
		my($src,$dst,$cname1, $nname2, $cname2) = @_;

		if ($src->jlink) {
			return &Janus::jmsg($dst, 'Please execute this command on your own server');
		}
		if ($src->homenet()->param('oper_only_link') && !$src->has_mode('oper')) {
			&Janus::jmsg($dst, "You must be an IRC operator to use this command");
			return;
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
		my $chan1 = $net1->chan($cname1,0) or do {
			&Janus::jmsg($dst, "Cannot find channel $cname1");
			return;
		};
		unless ($chan1->has_nmode(owner => $src) || $src->has_mode('oper')) {
			&Janus::jmsg($dst, "You must be a channel owner to use this command");
			return;
		}

		if (1 < scalar $chan1->nets()) {
			&Janus::jmsg($dst, 'That channel is already linked');
			return;
		}
		if ($Link::request{$net1->name()}{$cname1}{mode}) {
			&Janus::jmsg($dst, 'This network is the owner for that channel. Use DESTROY to change this');
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
		&Janus::jmsg($dst, "Link request sent");
	}
}, {
	cmd => 'create',
	help => 'Creates a channel that other networks can link to',
	details => [
		"Syntax: \002CREATE\002 #channel"
	],
	code => sub {
		my($src,$dst,$cname) = @_;

		my $net = $src->homenet;

		if ($net->jlink()) {
			return &Janus::jmsg($dst, 'Please execute this command on your own server');
		}
		if ($net->param('oper_only_link') && !$src->has_mode('oper')) {
			&Janus::jmsg($dst, "You must be an IRC operator to use this command");
			return;
		}

		my $chan = $cname && $net->chan($cname, 0);
		unless ($chan) {
			&Janus::jmsg($dst, $cname ? 'Cannot find that channel' : 'Syntax: CREATE #channel');
			return;
		}
		unless ($chan->has_nmode(owner => $src) || $src->has_mode('oper')) {
			&Janus::jmsg($dst, "You must be a channel owner to use this command");
			return;
		}
		if (1 < scalar $chan->nets) {
			&Janus::jmsg($dst, 'That channel is already linked');
			return;
		}
		&Log::audit("New channel $cname shared by ".$src->netnick);
		&Janus::append(+{
			type => 'LINKOFFER',
			src => $net,
			name => $cname,
			reqby => $src->realhostmask(),
			reqtime => $Janus::time,
		});
		&Janus::jmsg($dst, 'Done');
	},
}, {
	cmd => 'delink',
	help => 'Delinks a channel',
	details => [
		"Syntax: \002DELINK\002 #channel [network]",
	],
	code => sub {
		my($src,$dst, $cname, $nname) = @_;
		my $snet = $src->homenet;
		if ($snet->param('oper_only_link') && !$src->has_mode('oper')) {
			&Janus::jmsg($dst, "You must be an IRC operator to use this command");
			return;
		}
		my $chan = $snet->chan($cname) or do {
			&Janus::jmsg($dst, "Cannot find channel $cname");
			return;
		};
		unless ($src->has_mode('oper') || $chan->has_nmode(owner => $src)) {
			&Janus::jmsg($dst, "You must be a channel owner to use this command");
			return;
		}
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
	details => [
		"Syntax: \002DESTROY\002 #channel",
	],
	code => sub {
		my($src,$dst,$args) = @_;
		
		my $net = $src->homenet();

		if ($net->jlink()) {
			return &Janus::jmsg($dst, 'Please execute this command on your own server');
		}
		if ($net->param('oper_only_link') && !$src->has_mode('oper')) {
			&Janus::jmsg($dst, "You must be an IRC operator to use this command");
			return;
		}

		my $cname = $args =~ /^(#\S*)/ ? $1 : undef;
		my $chan = $cname && $net->chan($cname, 0);
		unless ($chan) {
			&Janus::jmsg($dst, $cname ? 'Cannot find that channel' : 'Syntax: DESTROY #channel');
			return;
		}
		unless ($chan->has_nmode(owner => $src) || $src->has_mode('oper')) {
			&Janus::jmsg($dst, "You must be a channel owner to use this command");
			return;
		}
		unless ($chan->homenet() == $net) {
			&Janus::jmsg($dst, "This command must be run from the channel's home network");
			return;
		}
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
