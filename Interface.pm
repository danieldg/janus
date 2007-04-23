package Interface; {
use Object::InsideOut qw(Network);
use Nick;
use strict;
use warnings;

sub banify {
	local $_ = $_[0];
	unless (s/^~//) { # all expressions starting with a ~ are raw perl regexes
		s/(\W)/\\$1/g;
		s/\\\?/./g;  # ? matches one char...
		s/\\\*/.*/g; # * matches any chars...
	}
	$_;
}

my %cmds = (
	unk => sub {
		my $nick = shift;
		Janus::jmsg($nick, 'Unknown command. Use "help" to see available commands');
	}, help => sub {
		my $nick = shift;
		Janus::jmsg($nick, 'Janus2 Help',
			' link $localchan $network $remotechan - links a channel with a remote network',
			' delink $chan - delinks a channel from all other networks',
			'These commands are restricted to IRC operators:',
			' ban list - list all active janus bans',
			' ban add $expr $reason $expire - add a ban',
			' ban kadd $expr $reason $expire - add a ban, and kill all users matching it',
			' ban del $expr|$index - remove a ban by expression or index in the ban list',
			'Bans are matched against nick!ident@host%network on any remote joins to a shared channel',
			' list - shows a list of the linked networks and shared channels',
			' rehash - reload the config and attempt to reconnect to split servers',
		);
	}, ban => sub {
		my $nick = shift;
		my($cmd, @arg) = split /\s+/;
		return Janus::jmsg("You must be an IRC operator to use this command") unless $nick->has_mode('oper');
		my $net = $nick->homenet();
		my @list = sort $net->banlist();
		if ($cmd =~ /^l/i) {
			my $c = 0;
			for my $expr (@list) {
				my $ban = $net->ban($expr);
				my $expire = $ban->{expire} ? 'expires on '.gmtime($ban->{expire}) : 'does not expire';
				$c++;
				Janus::jmsg($nick, "$c $ban->{ircexpr} - set by $ban->{setter}, $expire - $ban->{reason}");
			}
			Janus::jmsg($nick, 'No bans defined') unless @list;
		} elsif ($cmd =~ /^k?a/i) {
			unless ($arg[1]) {
				Janus::jmsg($nick, 'Use: ban add $expr $reason $duration');
				return;
			}
			my $expr = banify $arg[0];
			my %b = (
				expr => $expr,
				ircexpr => $arg[0],
				reason => $arg[1],
				expire => $arg[2] ? $arg[2] + time : 0,
				setter => $nick->homenick(),
			);
			$net->add_ban(\%b);
			if ($cmd =~ /^a/i) {
				Janus::jmsg($nick, 'Ban added');
			} else {
				my $c = 0;
				for my $n (values %{$net->_nicks()}) {
					next if $n->homenet()->id() eq $net->id();
					my $mask = $n->homenick().'!'.$n->info('ident').'\@'.$n->info('host').'%'.$n->homenet()->id();
					next unless $mask =~ /$expr/;
					Janus::append(+{
						type => 'KILL',
						dst => $n,
						net => $net,
						msg => 'Banned by '.$net->netname().': '.$arg[1],
					});
					$c++;
				}
				Janus::jmsg($nick, "Ban added, $c nick(s) killed");
			}
		} elsif ($cmd =~ /^d/i) {
			for (@arg) {
				my $expr = /^\d+$/ ? $list[$_ - 1] : banify $_;
				my $ban = $net->remove_ban($expr);
				if ($ban) {
					Janus::jmsg($nick, "Ban $ban->{ircexpr} removed");
				} else {
					Janus::jmsg($nick, "Could not find ban $_ - use ban list to see a list of all bans");
				}
			}
		}
	}, list => sub {
		my $nick = shift;
		return Janus::jmsg($nick, "You must be an IRC operator to use this command") unless $nick->has_mode('oper');
		Janus::jmsg($nick, 'Linked networks: '.join ' ', sort keys %Janus::nets);
		my $hnet = $nick->homenet();
		my $chans = $hnet->_chans();
		for my $cname (sort keys %$chans) {
			my $chan = $chans->{$cname};
			my @nets = $chan->nets();
			next if @nets == 1;
			my $list = ' '.$chan->str($hnet);
			for my $net (sort @nets) {
				next if $net->id() eq $hnet->id();
				$list .= ' '.$net->id().$chan->str($net);
			}
			Janus::jmsg($nick, $list);
		}
	}, 'link' => sub {
		my $nick = shift;
		return Janus::jmsg($nick, "You must be an IRC operator to use this command") 
			if $nick->homenet()->param('oper_only_link') && !$nick->has_mode('oper');
		my($cname1, $nname2, $cname2) = /(#\S+)\s+(\S+)\s*(#\S+)?/ or do {
			Janus::jmsg($nick, 'Usage: link $localchan $network $remotechan');
			return;
		};

		my $net1 = $nick->homenet();
		my $net2 = $Janus::nets{lc $nname2} or do {
			Janus::jmsg($nick, "Cannot find network $nname2");
			return;
		};
		my $chan1 = $net1->chan($cname1,0) or do {
			Janus::jmsg($nick, "Cannot find channel $cname1");
			return;
		};
		unless ($chan1->has_nmode(n_owner => $nick) || $nick->has_mode('oper')) {
			Janus::jmsg($nick, "You must be a channel owner to use this command");
			return;
		}
	
		Janus::append(+{
			type => 'LINKREQ',
			src => $nick,
			dst => $net2,
			net => $net1,
			slink => $cname1,
			dlink => ($cname2 || 'any'),
			sendto => [ $net2 ],
			override => $nick->has_mode('oper'),
		});
		Janus::jmsg($nick, "Link request sent");
	}, 'delink' => sub {
		my($nick, $cname) = @_;
		my $snet = $nick->homenet();
		if ($snet->param('oper_only_link') && !$nick->has_mode('oper')) {
			Janus::jmsg($nick, "You must be an IRC operator to use this command");
			return;
		}
		my $chan = $snet->chan($cname) or do {
			Janus::jmsg($nick, "Cannot find channel $cname");
			return;
		};
		unless ($nick->has_mode('oper') || $chan->has_nmode(n_owner => $nick)) {
			Janus::jmsg($nick, "You must be a channel owner to use this command");
			return;
		}
			
		Janus::append(+{
			type => 'DELINK',
			src => $nick,
			dst => $chan,
			net => $snet,
		});
	}, rehash => sub {
		my $nick = shift;
		return Janus::jmsg($nick, "You must be an IRC operator to use this command") unless $nick->has_mode('oper');
		Janus::append(+{
			type => 'REHASH',
			sendto => [],
		});
		Janus::jmsg($nick, "Rehashed");
#	}, 'die' => sub {
#		my $nick = shift;
#		return Janus::jmsg("You must be an IRC operator to use this command") unless $nick->has_mode('oper');
#		exit 0;
	},
);

sub modload {
	my $class = shift;
	my $inick = shift || 'janus';

	my $int = Interface->new(
		id => 'janus',
	);
	$int->configure(+{
		netname => 'Janus',
	});
	$int->_connect();
	Janus::link($int);

	$Janus::interface = Nick->new(
		net => $int,
		nick => $inick,
		ts => 100000000,
		info => {
			ident => 'janus',
			host => 'services.janus',
			vhost => 'services',
			name => 'Janus Control Interface',
			_is_janus => 1,
		},
		mode => { oper => 1, service => 1, bot => 1 },
	);
	$int->nick_collide($inick, $Janus::interface);
	
	Janus::hook_add($class, 
		NETLINK => act => sub {
			my $act = shift;
			Janus::append(+{
				type => 'CONNECT',
				dst => $Janus::interface,
				net => $act->{net},
			});
#		}, NETSPLIT => act => sub {
#			my $act = shift;
#			my $net = $act->{net};
#			delete $Janus::interface->{nets}->{$net->id()};
#			my $jnick = delete $Janus::interface->{nicks}->{$net->id()};
#			$net->release_nick($jnick);
		}, MSG => parse => sub {
			my $act = shift;
			my $nick = $act->{src};
			my $dst = $act->{dst};
			return undef unless $nick->isa('Nick') && $dst->isa('Nick');
			if ($dst->info('_is_janus')) {
				return 1 if $act->{msgtype} != 1 || !$nick;
				local $_ = $act->{msg};
				my $cmd = s/^\s*(\S+)\s*// && exists $cmds{lc $1} ? lc $1 : 'unk';
				$cmds{$cmd}->($nick, $_);
				return 1;
			}
			
			unless ($nick->is_on($dst->homenet())) {
				Janus::append(+{
					type => 'MSG',
					msgtype => 2,
					src => $Janus::interface,
					dst => $nick,
					msg => 'You must join a shared channel to speak with remote users',
				}) if $act->{msgtype} == 1;
				return 1;
			}
			undef;
		}, LINKREQ => act => sub {
			my $act = shift;
			my $snet = $act->{net};
			my $dnet = $act->{dst};
			return if $dnet->jlink();
			my $recip = $dnet->is_req($act->{dlink}, $snet);
			if ($act->{linkfile} && $dnet->is_synced() || $recip && 
					($act->{override} || $recip eq 'any' || lc $recip eq lc $act->{slink})
			) {
				# there has already been a request to link this channel to that network
				# also, if it was not an override, the request was for this pair of channels
				$dnet->del_req($act->{dlink}, $snet);
				Janus::append(+{
					type => 'LSYNC',
					src => $dnet,
					dst => $snet,
					chan => $dnet->chan($act->{dlink},1),
					linkto => $act->{slink},
				});
			} else {
				$snet->add_req($act->{slink}, $dnet, $act->{dlink});
			}
		},
	);
}

sub parse { () }
sub send { }

} 1;
