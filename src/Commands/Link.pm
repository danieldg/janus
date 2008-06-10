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
		my($nick,$args) = @_;

		if ($nick->jlink()) {
			return &Janus::jmsg($nick, 'Please execute this command on your own server');
		}
		if ($nick->homenet()->param('oper_only_link') && !$nick->has_mode('oper')) {
			&Janus::jmsg($nick, "You must be an IRC operator to use this command");
			return;
		}

		my($cname1, $nname2, $cname2);
		if ($args =~ /(#\S*)\s+(\S+)\s*(#\S*)/) {
			($cname1, $nname2, $cname2) = ($1,$2,$3);
		} elsif ($args =~ /(#\S*)\s+(\S+)/) {
			($cname1, $nname2, $cname2) = ($1,$2,$1);
		} else {
			&Janus::jmsg($nick, 'Usage: LINK localchan network [remotechan]');
			return;
		}

		my $net1 = $nick->homenet();
		my $net2 = $Janus::nets{lc $nname2} or do {
			&Janus::jmsg($nick, "Cannot find network $nname2");
			return;
		};
		my $chan1 = $net1->chan($cname1,0) or do {
			&Janus::jmsg($nick, "Cannot find channel $cname1");
			return;
		};
		unless ($chan1->has_nmode(owner => $nick) || $nick->has_mode('oper')) {
			&Janus::jmsg($nick, "You must be a channel owner to use this command");
			return;
		}

		&Janus::append(+{
			type => 'LINKREQ',
			src => $nick,
			dst => $net2,
			net => $net1,
			slink => lc $cname1,
			dlink => lc $cname2,
			override => $nick->has_mode('oper'),
			reqby => $nick->realhostmask(),
			reqtime => $Janus::time,
		});
		&Janus::jmsg($nick, "Link request sent");
	}
}, {
	cmd => 'create',
	help => 'Creates a channel that other networks can link to',
	details => [
		"Syntax: \002CREATE\002 #channel"
	],
	code => sub {
		my($nick,$args) = @_;

		my $net = $nick->homenet();

		if ($net->jlink()) {
			return &Janus::jmsg($nick, 'Please execute this command on your own server');
		}
		if ($net->param('oper_only_link') && !$nick->has_mode('oper')) {
			&Janus::jmsg($nick, "You must be an IRC operator to use this command");
			return;
		}

		my $cname = $args =~ /^(#\S*)/ ? $1 : undef;
		my $chan = $cname && $net->chan($cname, 0);
		unless ($chan) {
			&Janus::jmsg($nick, $cname ? 'Cannot find that channel' : 'Syntax: CREATE #channel');
			return;
		}
		unless ($chan->has_nmode(owner => $nick) || $nick->has_mode('oper')) {
			&Janus::jmsg($nick, "You must be a channel owner to use this command");
			return;
		}
		&Janus::append(+{
			type => 'LINKOFFER',
			src => $net,
			name => $cname,
			reqby => $nick->realhostmask(),
			reqtime => $Janus::time,
		});
		&Janus::jmsg($nick, 'Done');
	},
}, {
	cmd => 'delink',
	help => 'Delinks a channel',
	details => [
		"Syntax: \002DELINK\002 #channel [network]",
	],
	code => sub {
		my($nick, $args) = @_;
		my $snet = $nick->homenet();
		if ($snet->param('oper_only_link') && !$nick->has_mode('oper')) {
			&Janus::jmsg($nick, "You must be an IRC operator to use this command");
			return;
		}
		$args && $args =~ /^(#\S*)(?:\s+(\S+))?/ or do {
			&Janus::jmsg($nick, "Syntax: DELINK #channel [network]");
			return;
		};
		my($cname,$nname) = ($1, $2);
		my $chan = $snet->chan($cname) or do {
			&Janus::jmsg($nick, "Cannot find channel $cname");
			return;
		};
		unless ($nick->has_mode('oper') || $chan->has_nmode(owner => $nick)) {
			&Janus::jmsg($nick, "You must be a channel owner to use this command");
			return;
		}
		if ($nname) {
			if ($snet != $chan->homenet()) {
				&Janus::jmsg($nick, 'This syntax can only be used by the network owning the channel');
				return;
			}
			$snet = $Janus::nets{$nname};
			unless ($snet) {
				&Janus::jmsg($nick, 'Could not find that network');
				return;
			}
		}

		&Janus::append(+{
			type => 'DELINK',
			src => $nick,
			dst => $chan,
			net => $snet,
		});
	},
});

1;
