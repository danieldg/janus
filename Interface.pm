# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Interface;
BEGIN {
	&Janus::load('Network');
	&Janus::load('Nick');
}
use Object::InsideOut qw(Network);
use Persist;
use strict;
use warnings;
our($VERSION) = '$Rev$' =~ /(\d+)/;

__CODE__

my $inick = $Conffile::netconf{janus}{janus} || 'janus';

if ($Janus::interface) {
	# we are being live-reloaded as a module. Don't recreate 
	# the network or nick, just reload commands
	print "Reloading Interface\n";
	if ($inick ne $Janus::interface->homenick()) {
		&Janus::insert_full(+{
			type => 'NICK',
			dst => $Janus::interface,
			nick => $inick,
			nickts => 100000000,
		});
	}
	Interface->new(id => '__reloader__');
} else {
	my $int = Interface->new(
		id => 'janus',
	);
	$int->_set_netname('Janus');
	&Janus::link($int);

	$Janus::interface = Nick->new(
		net => $int,
		nick => $inick,
		ts => 100000000,
		info => {
			ident => 'janus',
			host => 'services.janus',
			vhost => 'services',
			name => 'Janus Control Interface',
			opertype => 'Janus Service',
			_is_janus => 1,
		},
		mode => { oper => 1, service => 1, bot => 1 },
	);
	&Janus::insert_full(+{
		type => 'NEWNICK',
		dst => $Janus::interface,
	});
}

&Janus::hook_add(
	LINKED => act => sub {
		my $act = shift;
		my $net = $act->{net};
		return if $net->jlink();
		&Janus::append(+{
			type => 'CONNECT',
			dst => $Janus::interface,
			net => $net,
		});
	}, NETSPLIT => act => sub {
		my $act = shift;
		$Janus::interface->_netpart($act->{net});
	}, MSG => parse => sub {
		my $act = shift;
		my $src = $act->{src};
		my $dst = $act->{dst};
		my $type = $act->{msgtype};
		return 1 unless ref $src && ref $dst;

		if ($type eq '312') {
			# server whois reply message
			if ($src->isa('Network')) {
				&Janus::append(+{
					type => 'MSG',
					msgtype => 640,
					src => $src,
					dst => $dst,
					msg => [
						$act->{msg}->[0],
						"is connected through a Janus link. Home network: ".$src->netname(),
					],
				});
			} else {
				warn "Source of /whois reply is not a server";
			}
			return undef;
		} elsif ($type eq '313') {
			# remote oper - change message type
			$act->{msgtype} = 641;
			$act->{msg}->[-1] .= ' (on remote network)';
			return 0;
		}
		return 1 if $type eq '310'; # available for help

		return undef unless $src->isa('Nick') && $dst->isa('Nick');
		if ($dst->info('_is_janus')) {
			return 1 unless $act->{msgtype} eq 'PRIVMSG' && $src;
			local $_ = $act->{msg};
			my $cmd = s/^\s*(\S+)\s*// ? lc $1 : 'unk';
			&Janus::in_command($cmd, $src, $_);
			return 1;
		}
		
		unless ($src->is_on($dst->homenet())) {
			&Janus::jmsg($src, 'You must join a shared channel to speak with remote users') if $act->{msgtype} eq 'PRIVMSG';
			return 1;
		}
		undef;
	}, WHOIS => parse => sub {
		my $act = shift;
		my $src = $act->{src};
		my $dst = $act->{dst};
		unless ($src->is_on($dst->homenet())) {
			&Janus::jmsg($src, 'You cannot use this /whois syntax unless you are on a shared channel with the user');
			return 1;
		}
		undef;
	}, LINKREQ => validate => sub {
		my $act = shift;
		my $valid = eval {
			return 0 unless $act->{net}->isa('Network');
			return 0 unless $act->{dst}->isa('Network');
			return 0 unless $act->{dlink} =~ /^#/;
			1;
		};
		$valid ? undef : 1;		
	}, LINKREQ => act => sub {
		my $act = shift;
		my $snet = $act->{net};
		my $dnet = $act->{dst};
		print "Link request:";
		if ($dnet->jlink()) { 
			print " dst non-local";
		} else {
			my $recip = $dnet->is_req($act->{dlink}, $snet);
			print $recip ? " dst req:$recip" : " dst new req";
			$recip = 'any' if $recip && $act->{override};
			if ($act->{linkfile}) {
				if ($dnet->is_synced()) {
					print '; linkfile: override';
					$recip = 'any';
				} else {
					$recip = '';
					print '; linkfile: not synced';
				}
			}
			if ($recip && ($recip eq 'any' || lc $recip eq lc $act->{slink})) {
				print " => LINK OK!\n";
				# there has already been a request to link this channel to that network
				# also, if it was not an override, the request was for this pair of channels
				$dnet->del_req($act->{dlink}, $snet);
				&Janus::append(+{
					type => 'LSYNC',
					src => $dnet,
					dst => $snet,
					chan => $dnet->chan($act->{dlink},1),
					linkto => $act->{slink},
					linkfile => $act->{linkfile},
				});
				# do not add it to request list now
				return;
			}
		}
		if ($snet->jlink()) {
			print "; src non-local\n";
		} else {
			$snet->add_req($act->{slink}, $dnet, $act->{dlink});
			print "; added to src requests\n";
		}
	},
);
&Janus::command_add({
	cmd => 'info',
	help => 'Provides information about janus',
	code => sub {
		my $nick = shift;
		&Janus::jmsg($nick, 
			'Janus is a server that allows IRC networks to share certain channels to other',
			'linked networks without needing to share all channels and make all users visible',
			'across both networks. If configured to allow it, users can also share their own',
			'channels across any linked network.',
			'-------------------------',
			'The source code can be found at http://danieldegraaf.afraid.org/janus/trunk/',
			'This file was checked out from $URL$',
			'If you make any modifications to this software, you must change these URLs',
			'to one which allows downloading the version of the code you are running.'
		);
	}
}, {
	cmd => 'modules',
	help => 'Version information on all modules loaded by janus',
	code => sub {
		my $nick = shift;
		opendir my $dir, '.' or return warn $!;
		&Janus::jmsg($nick, 'Janus socket core:'.$main::VERSION);
		for my $itm (sort readdir $dir) {
			next unless $itm =~ /^([0-9_A-Za-z]+)\.pm$/;
			my $mod = $1;
			no strict 'refs';
			my $v = ${$mod.'::VERSION'};
			next unless $v; # not loaded
			&Janus::jmsg($nick, "$mod:$v");
		}
		closedir $dir;
	}
}, {
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
			my $list = ' '.$chan->str($hnet);
			for my $net (sort @nets) {
				next if $net->id() eq $hnet->id();
				$list .= ' '.$net->id().$chan->str($net);
			}
			push @chans, $list;
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
		"Syntax: \002DELINK\002 #channel [network]",
	],
	code => sub {
		my($nick, $args) = @_;
		my $snet = $nick->homenet();
		if ($snet->param('oper_only_link') && !$nick->has_mode('oper')) {
			&Janus::jmsg($nick, "You must be an IRC operator to use this command");
			return;
		}
		$args && $args =~ /^(#\S*)(?:\s*(\S+))/ or do {
			&Janus::jmsg($nick, "Syntax: DELINK #channel [network]");
			return;
		};
		my($cname,$nname) = ($1,$2);
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
		});
	},
}, {
	cmd => 'rehash',
	help => 'Reload the config and attempt to reconnect to split servers',
	code => sub {
		my($nick,$pass) = @_;
		unless ($nick->has_mode('oper') || $pass eq $Conffile::netconf{janus}{pass}) {
			&Janus::jmsg($nick, "You must be an IRC operator or specify the rehash password to use this command");
			return;
		}
		&Janus::append(+{
			src => $nick,
			type => 'REHASH',
			sendto => [],
		});
	},
}, {
	cmd => 'die',
	help => "Kill the janus server; does \002NOT\002 restart it",
	details => [
		"Syntax: \002DIE\002 diepass",
	],
	code => sub {
		my($nick,$pass) = @_;
		unless ($nick->has_mode('oper') && $pass && $pass eq $Conffile::netconf{janus}{diepass}) {
			&Janus::jmsg($nick, "You must be an IRC operator and specify the 'diepass' password to use this command");
			return;
		}
		exit;
	},
}, {
	cmd => 'restart',
	help => "Restart the janus server",
	details => [
		"Syntax: \002RESTART\002 diepass",
	],
	code => sub {
		my($nick,$pass) = @_;
		unless ($nick->has_mode('oper') && $pass && $pass eq $Conffile::netconf{janus}{diepass}) {
			&Janus::jmsg($nick, "You must be an IRC operator and specify the 'diepass' password to use this command");
			return;
		}
		for my $net (values %Janus::nets) {
			next if $net->jlink();
			&Janus::append(+{
				type => 'NETSPLIT',
				net => $net,
				msg => 'Restarting...',
			});
		}
		# Clean up all non-LocalNetwork items in the I/O queue
		for my $itm (keys %Janus::netqueues) {
			my $net = $Janus::netqueues{$itm}[3];
			unless (ref $net && $net->isa('LocalNetwork')) {
				delete $Janus::netqueues{$itm};
			}
		}
		# the I/O queue could possibly be empty by now; add an item to force it to stay around
		$Janus::netqueues{RESTARTER} = [ undef, undef, undef, undef, 0, 0 ];
		# sechedule the actual exec at a later time to try to send the restart netsplit message around
		&Janus::schedule(+{
			delay => 2,
			code => sub {
				$ENV{PATH} = '/usr/bin';
				exec 'perl -T janus.pl';
			},
		});
	},
}, {
	cmd => 'autoconnect',
	help => 'Enable or disable autoconnect on a network',
	details => [
		"Syntax: \002AUTOCONNECT\002 network [0|1]",
		"Enables or disables the automatic reconnection that janus makes to a network.",
		"A rehash will reread the value for the network from the janus configuration",
	],
	code => sub {
		my($nick, $args) = @_;
		return &Janus::jmsg($nick, "You must be an IRC operator to use this command") unless $nick->has_mode('oper');
		my($id, $onoff) = ($args =~ /(\S+) (\d)/) or do {
			&Janus::jmsg($nick, "Syntax: \002AUTOCONNECT\002 network [0|1]");
			return;
		};
		my $nconf = $Conffile::netconf{$id} or do {
			&Janus::jmsg($nick, 'Cannot find network');
			return;
		};
		$nconf->{autoconnect} = $onoff;
		&Janus::jmsg($nick, 'Done');
	},
}, {
	cmd => 'netsplit',
	help => 'Split a network and reconnect to it',
	details => [
		"Syntax: \002NETSPLIT\002 network",
		"Disconnects the given network from janus and then rehashes to (possibly) reconnect",
	],
	code => sub {
		my $nick = shift;
		return &Janus::jmsg($nick, "You must be an IRC operator to use this command") unless $nick->has_mode('oper');
		my $net = $Janus::nets{lc $_} or return;
		return if $net->jlink();
		&Janus::append(+{
			type => 'NETSPLIT',
			net => $net,
			msg => 'Forced split by '.$nick->homenick().' on '.$nick->homenet()->id()
		}, {
			type => 'REHASH',
			sendto => [],
		});
	},
}, {
	cmd => 'renick',
	# hidden command, no help
	code => sub {
		my($nick,$name) = @_;
		return &Janus::jmsg($nick, "You must be an IRC operator to use this command") unless $nick->has_mode('oper');
		$Conffile::netconf{janus}{janus} = $name;
		&Janus::reload('Interface');
	},
}, {
	cmd => 'save',
	help => "Save the current linked channels for this network",
	code => sub {
		my($nick) = @_;
		return &Janus::jmsg($nick, "You must be an IRC operator to use this command") unless $nick->has_mode('oper');
		my $hnet = $nick->homenet();
		my @file;
		for my $chan ($hnet->all_chans()) {
			my @nets = $chan->nets();
			next if @nets == 1;
			for my $net (sort @nets) {
				next if $net->id() eq $hnet->id();
				push @file, join ' ', $chan->str($hnet), $net->id(), $chan->str($net);
			}
		}
		$hnet->id() =~ /^([0-9a-z_A-Z]+)$/ or return warn;
		open my $f, '>', "links.$1.conf" or do {
			&Janus::err_jmsg($nick, "Could not open links file for net $1 for writing: $!");
			return;
		};
		print $f join "\n", @file, '';
		close $f or warn $!;
		&Janus::jmsg($nick, 'Link file saved');
	},
}, {
	cmd => 'reload',
	help => "Load or reload a module, live. \002EXPERIMENTAL\002.",
	details => [
		"Syntax: \002RELOAD\002 module",
		"\002WARNING\002: Reloading core modules may introduce bugs because of persistance",
		"of old code by the perl interpreter, and because Object::InsideOut methods may expire"
	],
	code => sub {
		my($nick,$name) = @_;
		return &Janus::jmsg($nick, "You must be an IRC operator to use this command") unless $nick->has_mode('oper');
		return &Janus::jmsg($nick, "Invalid module name") unless $name =~ /^([0-9_A-Za-z]+)$/;
		my $n = $1;
		if (&Janus::reload($n)) {
			&Janus::err_jmsg($nick, "Module reloaded");
		} else {
			&Janus::err_jmsg($nick, "Module load failed: $@");
		}
	},
}, {
	cmd => 'chatops',
	help => 'Send a messge to opers on all other networks',
	details => [
		"Syntax: \002CHATOPS\002 message",
		'The command /chatops, if available, can also be relayed',
	],
	code => sub {
		my($nick,$msg) = @_;
		return &Janus::jmsg($nick, "You must be an IRC operator to use this command") unless $nick->has_mode('oper');
		&Janus::append(+{
			type => 'CHATOPS',
			src => $nick,
			sendto => [ values %Janus::nets ],
			msg => $msg,
		});
	},
}, {
	cmd => 'chatto',
	help => 'Send a message to all opers on a specific network',
	details => [
		"Syntax: \002CHATTO\002 network message",
	],
	code => sub {
		my($nick,$msg) = @_;
		return &Janus::jmsg($nick, "You must be an IRC operator to use this command") unless $nick->has_mode('oper');
		$msg =~ s/^(\S+) // or return;
		my $net = $Janus::nets{$1} or return;
		&Janus::append(+{
			type => 'CHATOPS',
			src => $nick,
			dst => $net,
			msg => $msg,
		});
	},
});

sub parse { () }
sub send { }
sub request_nick { $_[2] }
sub release_nick { }
sub all_nicks { $Janus::interface }
sub all_chans { () }

1;
