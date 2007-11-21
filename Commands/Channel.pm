# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Commands::Channel;
use strict;
use warnings;
our($VERSION) = '$Rev$' =~ /(\d+)/;

&Janus::command_add({
	cmd => 'list',
	help => 'Shows a list of the linked networks and shared channels',
	code => sub {
		my $nick = shift;
		&Janus::jmsg($nick, 'Linked networks: '.join ' ', sort keys %Janus::nets);
		return unless $nick->has_mode('oper');
		my $hnet = $nick->homenet();
		my @chans;
		for my $chan ($hnet->all_chans()) {
			my @nets = $chan->nets();
			next if @nets == 1;
			my @list;
			for my $net (@nets) {
				next if $net eq $hnet;
				push @list, $net->name().$chan->str($net);
			}
			push @chans, join ' ', '', $chan->str($hnet), sort @list;
		}
		&Janus::jmsg($nick, sort @chans);
	}
}, {
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
		if ($args =~ /(#\S+)\s+(\S+)\s*(#\S+)/) {
			($cname1, $nname2, $cname2) = ($1,$2,$3);
		} elsif ($args =~ /(#\S+)\s+(\S+)/) {
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
		unless ($chan1->has_nmode(n_owner => $nick) || $nick->has_mode('oper')) {
			&Janus::jmsg($nick, "You must be a channel owner to use this command");
			return;
		}
	
		&Janus::append(+{
			type => 'LINKREQ',
			src => $nick,
			dst => $net2,
			net => $net1,
			slink => $cname1,
			dlink => $cname2,
			sendto => [ $net2 ],
			override => $nick->has_mode('oper'),
		});
		&Janus::jmsg($nick, "Link request sent");
	}
}, {
	cmd => 'delink',
	help => 'Delinks a channel from all other networks',
	details => [
		"Syntax: \002DELINK\002 [network] #channel [reason]",
	],
	code => sub {
		my($nick, $args) = @_;
		my $snet = $nick->homenet();
		if ($snet->param('oper_only_link') && !$nick->has_mode('oper')) {
			&Janus::jmsg($nick, "You must be an IRC operator to use this command");
			return;
		}
		$args && $args =~ /^(?:([^#]\S*)\s+)?(#\S*)(?:\s+(.+))?/ or do {
			&Janus::jmsg($nick, "Syntax: DELINK [network] #channel [reason]");
			return;
		};
		my($nname,$cname,$reason) = ($1, $2, $3 || 'no reason');
		my $chan = $snet->chan($cname) or do {
			&Janus::jmsg($nick, "Cannot find channel $cname");
			return;
		};
		unless ($nick->has_mode('oper') || $chan->has_nmode(n_owner => $nick)) {
			&Janus::jmsg($nick, "You must be a channel owner to use this command");
			return;
		}
		$snet = $Janus::nets{$nname} if $nname;
		unless ($snet) {
			&Janus::jmsg($nick, 'Could not find that network');
			return;
		}

		&Janus::append(+{
			type => 'DELINK',
			src => $nick,
			dst => $chan,
			net => $snet,
			reason => $reason,
		});
	},
}, {
	cmd => 'save',
	help => "Save the current linked channels for this network",
	code => sub {
		my($nick) = @_;
		return &Janus::jmsg($nick, "You must be an IRC operator to use this command") unless $nick->has_mode('oper');
		my $hnet = $nick->homenet();
		my @file;
		my $reqs = $hnet->all_reqs();
		my %reqs = $reqs ? %$reqs : ();
		for my $chan ($hnet->all_chans()) {
			my @nets = $chan->nets();
			next if @nets == 1;
			for my $net (@nets) {
				next if $net eq $hnet;
				$reqs{$chan->str($hnet)}{$net->name()} = $chan->str($net);
			}
		}
		for my $chan (sort keys %reqs) {
			for my $net (sort keys %{$reqs{$chan}}) {
				push @file, join ' ', $chan, $net, $reqs{$chan}{$net};
			}
		}
		$hnet->name() =~ /^([0-9a-z_A-Z]+)$/ or return warn;
		open my $f, '>', "links.$1.conf" or do {
			&Janus::err_jmsg($nick, "Could not open links file for net $1 for writing: $!");
			return;
		};
		print $f join "\n", @file, '' or warn $!;
		close $f or warn $!;
		&Janus::jmsg($nick, 'Link file saved');
	},
});

1;
