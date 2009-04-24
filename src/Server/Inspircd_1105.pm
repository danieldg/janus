# Copyright (C) 2007-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Server::Inspircd_1105;
use Nick;
use Modes;
use Util::BaseNick;
use Util::BaseParser;
use Util::ModularNetwork;
use Server::InspMods;
use Util::Crypto;

use Persist 'Util::BaseNick', 'Util::BaseParser', 'Util::ModularNetwork';
use strict;
use warnings;

our(@auth_sendq, @servers, @serverdsc, @capabs, @txt2pfx, @pfx2txt);
Persist::register_vars(qw(auth_sendq servers serverdsc capabs txt2pfx pfx2txt));

sub _init {
	my $net = shift;
	$auth_sendq[$$net] = '';
	$net->module_add('CORE');
}

sub ignore { () }

sub nicklen {
	my $net = shift;
	($capabs[$$net]{NICKMAX} || 32) - 2;
}

sub str {
	my $net = shift;
	$net->jname();
}

sub intro {
	my($net,@param) = @_;
	$net->SUPER::intro(@param);
	my @out;
	$auth_sendq[$$net] .= "CAPAB START\r\n";
	# we cannot continue until we get the remote CAPAB list so we can
	# forge the module list. However, we can set up the other server introductions
	# as they will be sent after auth is done
	$net->send($net->ncmd(VERSION => 'Janus Hub'));
}

sub inner_parse {
	my($net, $args, $line) = @_;
	my $cmd = $args->[1];
	Log::netin($net, $line) unless $cmd eq 'PRIVMSG' || $cmd eq 'NOTICE';
	unless ($net->auth_ok || $cmd eq 'CAPAB' || $cmd eq 'SERVER' || $cmd eq 'ERROR') {
		$auth_sendq[$$net] .= "ERROR :Not authorized yet\r\n";
		return 0;
	}
	1;
}

sub dump_sendq {
	my $net = shift;
	my $q = $auth_sendq[$$net];
	Log::netout($net, $_) for split /\r\n/, $q;
	$auth_sendq[$$net] = '';
	$q .= Util::BaseParser::dump_sendq($net) if $net->auth_ok;
	$q;
}

sub _connect_ifo {
	my ($net, $nick) = @_;

	my @out;

	my $mode = '+' . $net->umode_to_irc([ $nick->umodes ], $nick, \@out);

	my $srv = $nick->homenet()->jname();
	$srv = $net->cparam('linkname') if $srv eq 'janus.janus';

	my $ip = $nick->info('ip') || '0.0.0.0';
	$ip = '0.0.0.0' if $ip eq '*' || $net->param('untrusted');
	if ($nick->has_mode('oper')) {
		my $type = $nick->info('opertype') || 'IRC Operator';
		my $visible = Setting::get(oper_visibility => $net);
		$visible = 3 if $nick == $Interface::janus;
		my $suffix = $visible < 3 ? ' (remote)' : '';
		if ($visible == 1) {
			my $ho = $net->umode_to_irc([ 'hideoper' ], $nick);
			$mode .= $ho if defined $ho && -1 == index $mode, $ho;
		}
		my $len = $net->nicklen() - length $suffix;
		$type = substr($type, 0, $len).$suffix;
		$type =~ s/ /_/g;
		push @out, $net->cmd2($nick, OPERTYPE => $type) if $visible;
	}
	push @out, $net->cmd2($nick, AWAY => $nick->info('away')) if $nick->info('away');
	my $host = $nick->info($net->param('untrusted') ? 'vhost' : 'host');
	unshift @out, $net->cmd2($srv, NICK => $nick->ts($net), $nick, $host, $nick->info('vhost'),
		$nick->info('ident'), $mode, $ip, $nick->info('name'));

	@out;
}

sub process_capabs {
	my $net = shift;
	# NICKMAX=32 - done below in nicklen()
	# HALFOP=1
	if ($capabs[$$net]{HALFOP}) {
		$net->module_add('CAPAB_HALFOP');
	}
	# CHANMAX=65 - not applicable, we never send channels we have not heard before
	# MAXMODES=20 - checked when calling to_multi
	# IDENTMAX=12 - TODO
	# MAXQUIT=255 - TODO
	# MAXTOPIC=307 - TODO
	# MAXKICK=255 - TODO
	# MAXGECOS=128 -TODO
	# MAXAWAY=200 - TODO
	# IP6NATIVE=1 IP6SUPPORT=1 - we currently require IPv6 support, and claim to be native because we're cool like that :)
	# PROTOCOL=1105
	# PREFIX=(qaohv)~&@%+
	$capabs[$$net]{IP6SUPPORT} = 1;
	local $_ = $capabs[$$net]{PREFIX};

	my(%p2t,%t2p);
	my %cm2t = ( qw/q owner a admin o op h halfop v voice/ );
	while (s/\((.)(.*)\)(.)/($2)/) {
		my $txt = $cm2t{$1};
		$t2p{$txt} = $3;
		$p2t{$3} = $txt;
	}
	$pfx2txt[$$net] = \%p2t;
	$txt2pfx[$$net] = \%t2p;

#	my $expect = Modes::modelist($net, $modes);
#
#	unless ($expect eq $capabs[$$net]{CHANMODES}) {
#		$net->send($net->ncmd(OPERNOTICE => 'Possible desync - CHANMODES do not match module list: '.
#				"expected $expect, got $capabs[$$net]{CHANMODES}"));
#	}

	my $chall = delete $capabs[$$net]{CHALLENGE};
	my $sha2 = eval { require Digest::SHA; Digest::SHA->new('sha256') };
	if ($chall && $sha2) {
		$capabs[$$net]{' HMAC_SPASS'} = 'HMAC-SHA256:'.Util::Crypto::hmac_inspircd11_style($sha2, $net->cparam('sendpass'), $chall);

		$chall = Util::Crypto::salt(20, $net, $chall);
		$capabs[$$net]{CHALLENGE} = $chall;

		$capabs[$$net]{' HMAC_RPASS'} = 'HMAC-SHA256:'.Util::Crypto::hmac_inspircd11_style($sha2, $net->cparam('recvpass'), $chall);
	}
}

sub protoctl {
	my $net = shift;
	$capabs[$$net]{PROTOCOL}
}

sub lc {
	my $o = $_[1];
	$o =~ tr#A-Z[]\\#a-z{}|#;
	$o;
}

our %moddef = ();
Janus::static('moddef');
$moddef{CAPAB_HALFOP} = {
	cmode => {
		h => 'n_halfop',
	}
};
$moddef{CORE} = {
  cmode => {
		b => 'l_ban',
		i => 'r_invite',
		k => 'v_key',
		l => 's_limit',
		'm' => 'r_moderated',
		n => 'r_mustjoin',
		o => 'n_op',
		p =>   't1_chanhide',
		's' => 't2_chanhide',
		t => 'r_topic',
		v => 'n_voice',
  },
  umode => {
		i => 'invisible',
		o => 'oper',
		w => 'wallops',
		'+' => '', # inspircd bug, fixed in 1.2: an extra + may be added to the umode at each hop
		'n', '', 's', '',
  },
  parse => {
	NICK => sub {
		my $net = shift;
		if (@_ < 10) {
			my $nick = $net->mynick($_[0]) or return ();
			my $stomp = $net->nick($_[2], 1);
			if ($stomp && $stomp != $nick) {
				$net->send({
					type => 'QUIT',
					dst => $stomp,
					msg => "Nickname collision ($_[0] -> $_[2])",
				});
				return +{
					type => 'QUIT',
					dst => $nick,
					msg => "Nickname collision ($_[0] -> $_[2])",
				}, {
					type => 'RECONNECT',
					dst => $stomp,
					net => $net,
					killed => 1,
					altnick => 1,
				};
			}
			return +{
				type => 'NICK',
				src => $nick,
				dst => $nick,
				nick => $_[2],
				nickts => (@_ == 4 ? $_[3] : $Janus::time),
			};
		}
		my $ip = $_[8];
		$ip = $1 if $ip =~ /^[0:]+:ffff:(\d+\.\d+\.\d+\.\d+)$/;
		my %nick = (
			net => $net,
			ts => $_[2],
			nick => $_[3],
			info => {
				home_server => $_[0],
				host => $_[4],
				vhost => $_[5],
				ident => $_[6],
				signonts => $Janus::time,
				ip => $ip,
				name => $_[-1],
			},
		);
		my $modes = $net->umode_from_irc($_[7]);
		$nick{mode} = { map { /\+(.*)/ ? ($1 => 1) : () } @$modes };

		my @out;
		my $nick = $net->nick($_[3], 1);
		if ($nick) {
			# collided. Inspircd 1.1 method: kill them all!
			push @out, +{
				type => 'RECONNECT',
				dst => $nick,
				net => $net,
				killed => 1,
				altnick => 1,
			};
			$net->send($net->ncmd(KILL => $_[3], 'Nick collision'));
		} else {
			$nick = Nick->new(%nick);
			$net->request_newnick($nick, $_[3]);
			push @out, +{
				type => 'NEWNICK',
				dst => $nick,
			};
		}

		@out;
	}, OPERTYPE => sub {
		my $net = shift;
		my $nick = $net->mynick($_[0]) or return ();
		my $otype = $_[2];
		$otype =~ s/_/ /g;
		return +{
			type => 'UMODE',
			dst => $nick,
			mode => [ '+oper' ],
		},+{
			type => 'NICKINFO',
			dst => $nick,
			item => 'opertype',
			value => $otype,
		};
	}, OPERQUIT => sub {
		(); # that's only of interest to local opers
	}, AWAY => sub {
		my $net = shift;
		my $nick = $net->mynick($_[0]) or return ();
		return +{
			dst => $nick,
			type => 'NICKINFO',
			item => 'away',
			value => $_[2],
		};
	}, FHOST => sub {
		my $net = shift;
		my $nick = $net->mynick($_[0]) or return ();
		return +{
			type => 'NICKINFO',
			dst => $nick,
			item => 'vhost',
			value => $_[2],
		};
	}, FNAME => sub {
		my $net = shift;
		my $nick = $net->mynick($_[0]) or return ();
		return +{
			type => 'NICKINFO',
			dst => $nick,
			item => 'name',
			value => $_[2],
		};
	}, QUIT => sub {
		my $net = shift;
		my $nick = $net->mynick($_[0]) or return ();
		return +{
			type => 'QUIT',
			dst => $nick,
			msg => $_[-1],
		};
	}, KILL => sub {
		my $net = shift;
		my $src = $net->item($_[0]);
		my $dst = $net->nick($_[2]) or return ();
		my $msg = $_[3];
		$msg =~ s/^\S+!//;

		if ($dst->homenet() eq $net) {
			return {
				type => 'QUIT',
				dst => $dst,
				msg => $msg,
				killer => $src,
			};
		}
		if ($_[3] eq 'Nickname collision') {
			return {
				type => 'RECONNECT',
				dst => $dst,
				net => $net,
				killed => 1,
				altnick => 1,
			};
		}

		return {
			type => 'KILL',
			src => $src,
			dst => $dst,
			net => $net,
			msg => $msg,
		};
	}, FJOIN => sub {
		my $net = shift;
		my $ts = $_[3];
		my $chan = $net->chan($_[2], $ts);
		my $applied = ($chan->ts() >= $ts);
		my @acts;

		if ($chan->ts > $ts) {
			my $syncact = +{
				type => 'CHANTSSYNC',
				src => $net,
				dst => $chan,
				newts => $ts,
				oldts => $chan->ts(),
			};
			push @acts, $syncact;
			if ($chan->homenet == $net) {
				my($modes,$args,$dirs) = Modes::delta($chan, undef, $net);
				# this is a TS wipe, justified. Wipe janus's side.
				$_ = '-' for @$dirs;
				push @acts, +{
					type => 'MODE',
					src => $net,
					dst => $chan,
					mode => $modes,
					args => $args,
					dirs => $dirs,
				};
			} else {
				# someone else owns the channel. Fix.
				$net->send($syncact);
			}
		}

		for my $nm (split / /, $_[-1]) {
			$nm =~ /(?:(.*),)?(\S+)$/ or next;
			my $nmode = $1;
			my $nick = $net->mynick($2) or next;
			my %mh = map {
				$_ = $pfx2txt[$$net]{$_};
				$_ ? ($_ => 1) : ();
			} split //, $nmode;
			push @acts, +{
				type => 'JOIN',
				src => $nick,
				dst => $chan,
				mode => ($applied ? \%mh : undef),
			};
		}
		@acts;
	}, JOIN => sub {
		my $net = shift;
		my $src = $net->mynick($_[0]);
		my $ts = $_[3];
		map {
			my $chan = $net->chan($_, $ts);
			+{
				type => 'JOIN',
				src => $src,
				dst => $chan,
			};
		} split /,/, $_[2];
	}, FMODE => sub {
		my $net = shift;
		my $src = $net->item($_[0]);
		my $chan = $net->chan($_[2]) or return ();
		my $ts = $_[3];
		return () if $ts > $chan->ts();
		my($modes,$args,$dirs) = $net->cmode_from_irc($chan, @_[4 .. $#_]);
		return +{
			type => 'MODE',
			src => $src,
			dst => $chan,
			mode => $modes,
			args => $args,
			dirs => $dirs,
		};
	}, MODE => sub {
		my $net = shift;
		my $src = $net->item($_[0]);
		my $dst = $net->item($_[2]) or return ();
		if ($dst->isa('Nick')) {
			return () unless $dst->homenet == $net;
			my $mode = $net->umode_from_irc($_[3]);
			return {
				type => 'UMODE',
				src => $src,
				dst => $dst,
				mode => $mode,
			};
		} else {
			my($modes,$args,$dirs) = $net->cmode_from_irc($dst, @_[3 .. $#_]);
			return +{
				type => 'MODE',
				src => $src,
				dst => $dst,
				mode => $modes,
				args => $args,
				dirs => $dirs,
			};
		}
	}, REMSTATUS => sub {
		my $net = shift;
		my $chan = $net->chan($_[2]) or return ();
		my($modes,$args,$dirs) = Modes::delta($chan, undef, $net);
		return +{
			type => 'MODE',
			src => $net,
			dst => $chan,
			mode => $modes,
			args => $args,
			dirs => $dirs,
		};
	}, FTOPIC => sub {
		my $net = shift;
		return +{
			type => 'TOPIC',
			src => $net->item($_[0]),
			dst => $net->chan($_[2]),
			topicts => $_[3],
			topicset => $_[4],
			topic => $_[-1],
			in_link => 1,
		};
	}, TOPIC => sub {
		my $net = shift;
		return +{
			type => 'TOPIC',
			src => $net->item($_[0]),
			dst => $net->chan($_[2]),
			topicts => $Janus::time,
			topicset => $_[0],
			topic => $_[-1],
		};
	}, PART => sub {
		my $net = shift;
		return map +{
			type => 'PART',
			src => $net->mynick($_[0]),
			dst => $net->chan($_),
			msg => $_[3],
		}, split /,/, $_[2];
	}, KICK => sub {
		my $net = shift;
		my $nick = $net->nick($_[3]) or return ();
		return {
			type => 'KICK',
			src => $net->item($_[0]),
			dst => $net->chan($_[2]),
			kickee => $nick,
			msg => $_[4],
		};
	}, INVITE => sub {
		my $net = shift;
		my $src = $net->mynick($_[0]) or return ();
		my $dst = $net->nick($_[2]) or return ();
		my $chan = $net->chan($_[3]) or return ();
		return {
			type => 'INVITE',
			src => $src,
			dst => $dst,
			to => $chan,
		};
	}, SVSPART => sub {
		my $net = shift;
		my $nick = $net->nick($_[2]) or return ();
		my $chan = $net->chan($_[3]) or return ();
		$net->send({
			type => 'PART',
			src => $nick,
			dst => $chan,
			msg => 'Services forced part',
		});
		return +{
			type => 'KICK',
			src => $net->item($_[0]),
			dst => $chan,
			kickee => $nick,
			msg => 'Services forced part',
		};
	},

	SERVER => sub {
		my $net = shift;
		if ($net->auth_ok) {
			# recall parent
			$servers[$$net]{CORE::lc $_[2]} = CORE::lc $_[0];
			$serverdsc[$$net]{CORE::lc $_[2]} = $_[-1];
			return ();
		} else {
			my $rpass = delete $capabs[$$net]{' HMAC_RPASS'} || $net->cparam('recvpass');
			if ($_[3] eq $rpass) {
				$net->auth_recvd;
				if ($net->auth_should_send) {
					my $spass = delete $capabs[$$net]{' HMAC_SPASS'} || $net->cparam('sendpass');
					$auth_sendq[$$net] .= $net->cmd2(undef, SERVER => $net->cparam('linkname'),
						$spass, 0, $net, 'Janus Network Link') . "\r\n";
				}
				$auth_sendq[$$net] .= 'BURST '.$Janus::time."\r\n";
			} else {
				$auth_sendq[$$net] .= "ERROR :Bad password\r\n";
			}
			$serverdsc[$$net]{CORE::lc $_[2]} = $_[-1];
			$servers[$$net]{''} = CORE::lc $_[2];
			return ({
				type => 'NETLINK',
				net => $net,
			});
		}
	}, SQUIT => sub {
		my $net = shift;
		my $srv = $_[2];
		my $splitfrom = $servers[$$net]{CORE::lc $srv};

		my %sgone = (CORE::lc $srv => 1);
		my $k = 0;
		while ($k != scalar keys %sgone) {
			# loop to traverse each layer of the map
			$k = scalar keys %sgone;
			for (keys %{$servers[$$net]}) {
				$sgone{$_} = 1 if $sgone{$servers[$$net]{$_}};
			}
		}
		Log::info_in($net, 'Lost servers: '.join(' ', sort keys %sgone));
		delete $servers[$$net]{$_} for keys %sgone;
		delete $serverdsc[$$net]{$_} for keys %sgone;

		my @quits;
		for my $nick ($net->all_nicks()) {
			next unless $nick->homenet() eq $net;
			next unless $sgone{CORE::lc $nick->info('home_server')};
			push @quits, +{
				type => 'QUIT',
				src => $net,
				dst => $nick,
				msg => "$splitfrom $srv",
			}
		}
		@quits;
	}, RSQUIT => sub {
		# TODO we should really de- and re-introduce the server after this
		();
	}, PING => sub {
		my $net = shift;
		my $from = $_[3] || $net->cparam('linkname');
		$net->send($net->cmd2($from, 'PONG', $from, $_[2]));
		();
	},
	PONG => \&ignore,
	BURST => sub {
		();
	}, CAPAB => sub {
		my $net = shift;
		if ($_[2] eq 'MODULES') {
			$capabs[$$net]{' MOD'}{$_}++ for split /,/, $_[-1];
		} elsif ($_[2] eq 'CAPABILITIES') {
			$_ = $_[3];
			while (s/^\s*(\S+)=(\S+)//) {
				$capabs[$$net]{$1} = $2;
			}
		} elsif ($_[2] eq 'END') {
			# actually process what information we got
			my $modl = delete $capabs[$$net]{' MOD'} || {};
			$net->module_add($_) for keys %$modl;
			$net->process_capabs();

			# and then lie to match it
			my $mods = join ',', sort grep /so$/, $net->all_modules();
			my $capabs = join ' ', sort map {
				$_ . '=' . $capabs[$$net]{$_};
			} grep !/ /, keys %{$capabs[$$net]};

			my @out;
			push @out, 'CAPAB MODULES '.$1 while $mods =~ s/(.{1,495})(,|$)//;
			push @out, 'CAPAB CAPABILITIES :'.$1 while $capabs =~ s/(.{1,450})( |$)//;
			push @out, 'CAPAB END';
			if ($net->auth_should_send) {
				my $spass = delete $capabs[$$net]{' HMAC_SPASS'} || $net->cparam('sendpass');
				push @out, $net->cmd2(undef, SERVER => $net->cparam('linkname'), $spass, 0, 'Janus Network Link');
			}
			$auth_sendq[$$net] .= join "\r\n", @out, '';
		} # ignore START and any others
		();
	}, ERROR => sub {
		my $net = shift;
		+{
			type => 'NETSPLIT',
			net => $net,
			msg => 'ERROR: '.$_[-1],
		};
	},
	VERSION => \&ignore,
	ADDLINE => sub {
		my $net = shift;
		return +{
			type => 'XLINE',
			dst => $net,
			ltype => $_[2],
			mask => $_[3],
			setter => $_[4],
			settime => $_[5],
			expire => ($_[6] ? ($_[5] + $_[6]) : 0),
			reason => $_[7],
		};
	},
	GLINE => sub {
		my $net = shift;
		my $type = substr $_[1],0,1;
		if (@_ == 3) {
			return +{
				type => 'XLINE',
				dst => $net,
				ltype => $type,
				mask => $_[2],
				setter => $_[0],
				expire => 1,
			};
		} else {
			return +{
				type => 'XLINE',
				dst => $net,
				ltype => $type,
				mask => $_[2],
				setter => $_[0],
				settime => $Janus::time,
				expire => ($_[3] ? $Janus::time + $_[3] : 0),
				reason => $_[4],
			};
		}
	},
	ELINE => 'GLINE',
	ZLINE => 'GLINE',
	QLINE => 'GLINE',

	SVSJOIN => sub {
		my $net = shift;
		my $src = $net->mynick($_[2]) or return ();
		return map +{
			type => 'JOIN',
			src => $src,
			dst => $net->chan($_),
		}, split /,/, $_[3];
	},
	SVSNICK => sub {
		my $net = shift;
		my $nick = $net->nick($_[2]) or return ();
		if ($nick->homenet eq $net) {
			Log::warn_in($net, "Misdirected SVSNICK!");
			return ();
		} elsif ($net->lc($nick->homenick) eq $net->lc($_[2])) {
			return +{
				type => 'RECONNECT',
				src => $net->item($_[0]),
				dst => $nick,
				net => $net,
				killed => 0,
				altnick => 1,
				sendto => [ $net ],
			};
		} else {
			Log::warn_in($net, "Ignoring SVSNICK on already tagged nick");
			return ();
		}
	},
	SVSMODE => 'MODE',
	SVSHOLD => \&ignore,
	REHASH => sub {
		return +{
			type => 'REHASH',
		};
	},
	MODULES => \&ignore,
	ENDBURST => sub {
		my $net = shift;
		return (+{
			type => 'LINKED',
			net => $net,
		}, +{
			type => 'RAW',
			dst => $net,
			msg => 'ENDBURST',
		});
	},

	PRIVMSG => sub {
		my $net = shift;
		my $src = $net->item($_[0]);
		if ($_[2] =~ /^\$/) {
			# server broadcast message. No action; these are confined to source net
			return ();
		} elsif ($_[2] =~ /([^#]?)(#\S*)/) {
			# channel message, possibly to a mode prefix
			return {
				type => 'MSG',
				src => $src,
				prefix => $1,
				dst => $net->chan($2),
				msg => $_[3],
				msgtype => $_[1],
			};
		} elsif ($_[2] =~ /^(\S+?)(@\S+)?$/) {
			# nick message, possibly with a server mask
			# server mask is ignored as the server is going to be wrong anyway
			my $dst = $net->nick($1);
			return +{
				type => 'MSG',
				src => $src,
				dst => $dst,
				msg => $_[3],
				msgtype => $_[1],
			} if $dst;
		}
		();
	},
	NOTICE => 'PRIVMSG',
	OPERNOTICE => \&ignore,
	MODENOTICE => \&ignore,
	SNONOTICE => \&ignore,
	WALLOPS => \&ignore,
	RCONNECT => \&ignore,
	METADATA => sub {
		my $net = shift;
		my $key = $_[3];
		$net->do_meta($key, @_);
	},
	IDLE => sub {
		my $net = shift;
		my $src = $net->mynick($_[0]) or return ();
		my $dst = $net->nick($_[2]) or return ();
		if (@_ == 3) {
			return +{
				type => 'WHOIS',
				src => $src,
				dst => $dst,
			};
		} else {
			my $home_srv = $src->info('home_server');
			return Interface::whois_reply($dst, $src,
				$_[4], $_[3],
				312 => [ $home_srv, $serverdsc[$$net]{$home_srv} ],
			);
		}
	}, PUSH => sub {
		my $net = shift;
		my $dst = $net->nick($_[2]) or return ();
		my($rmsg, $txt) = split /\s+:/, $_[-1], 2;
		my @msg = split /\s+/, $rmsg;
		push @msg, $txt if defined $txt;
		unshift @msg, undef unless $msg[0] =~ s/^://;

		if ($$dst == 1) {
			# a PUSH to the janus nick. Don't send any events, for one.
			# However, it might be something we asked about, like the MODULES output
			if (@msg == 4 && $msg[1] eq '900' && $msg[0] && $msg[0] eq $servers[$$net]{''}) {
				if ($msg[3] =~ /^(\S+)$/) {
					$net->module_add($1);
				} elsif ($msg[3] =~ /^0x\S+ \S+ (\S+) \(.*\)$/) {
					# alternate form of above which is returned to opers
					$net->module_add($1);
				}
			}
			return ();
		}

		my $src = $net->item(shift @msg) || $net;
		my $cmd = shift @msg;
		shift @msg;
		return +{
			type => 'MSG',
			src => $net,
			dst => $dst,
			msgtype => $cmd,
			msg => (@msg == 1 ? $msg[0] : \@msg),
		};
	}, TIME => sub {
		my $net = shift;
		$net->send($net->cmd2(@_[2,1,0,3], $Janus::time)) if @_ == 4;
		();
	},
	TIMESET => \&ignore,

# from m_globalload.so, included so that dynamic module loading always works
	GLOADMODULE => sub {
		my $net = shift;
		$net->module_add($_[2]);
		();
	},
	GUNLOADMODULE => sub {
		my $net = shift;
		$net->module_remove($_[2]);
		();
	},
  }, 'send' => {
	JNETLINK => sub {
		my($net,$act) = @_;
		my $new = $act->{net};
		my $jid = $new->id().'.janus';
		($net->ncmd(SERVER => $jid, '*', 1, 'Inter-Janus link'),
		 $net->cmd2($jid, VERSION => 'Interjanus'));
	}, NETLINK => sub {
		my($net,$act) = @_;
		my $new = $act->{net};
		my @out;
		if ($net eq $new) {
			for my $ij (values %Janus::ijnets) {
				next unless $ij->is_linked();
				next if $ij eq $RemoteJanus::self;
				my $jid = $ij->id().'.janus';
				push @out, $net->ncmd(SERVER => $jid, '*', 1, 'Inter-Janus link');
				push @out, $net->cmd2($jid, VERSION => 'Interjanus');
			}
			for my $id (keys %Janus::nets) {
				my $new = $Janus::nets{$id};
				next if $new->isa('Interface') || $new eq $net;
				my $jl = $new->jlink();
				if ($jl) {
					push @out, $net->cmd2($jl->id().'.janus', SERVER =>
						$new->jname(), '*', 2, $new->netname());
				} else {
					push @out, $net->ncmd(SERVER => $new->jname(), '*', 1, $new->netname());
				}
				push @out, $net->cmd2($new->jname(), VERSION => 'Remote Janus Server: '.$new->type);
			}
		} else {
			my $jl = $new->jlink();
			if ($jl) {
				push @out, $net->cmd2($jl->id().'.janus', SERVER =>
					$new->jname(), '*', 2, $new->netname());
			} else {
				push @out, $net->ncmd(SERVER => $new->jname(), '*', 1, $new->netname());
			}
			push @out, $net->cmd2($new->jname(), VERSION => 'Remote Janus Server: '.$new->type);
			push @out, $net->ncmd(OPERNOTICE => "Janus network ".$new->name().' ('.$new->netname().") is now linked");
		}
		return @out;
	}, NETSPLIT => sub {
		my($net,$act) = @_;
		return () if $act->{netsplit_quit};
		my $gone = $act->{net};
		my $msg = $act->{msg} || 'Excessive Core Radiation';
		return (
			$net->ncmd(OPERNOTICE => "Janus network ".$gone->name().' ('.$gone->netname().") has delinked: $msg"),
			$net->ncmd(SQUIT => $gone->jname(), $msg),
		);
	}, JNETSPLIT => sub {
		my($net,$act) = @_;
		my $gone = $act->{net};
		my $jid = $gone->id().'.janus';
		my $msg = $act->{msg} || 'Excessive Core Radiation';
		return (
			$net->ncmd(OPERNOTICE => 'InterJanus network '.$gone->id()." has delinked: $msg"),
			$net->ncmd(SQUIT => $jid, $msg),
		);
	}, CONNECT => sub {
		my($net,$act) = @_;
		my $nick = $act->{dst};
		return () if $act->{net} ne $net;
		my @out = $net->_connect_ifo($nick);
		push @out, $net->cmd2($nick, MODULES => $servers[$$net]{''}) if $$nick == 1;
		@out;
	}, RECONNECT => sub {
		my($net,$act) = @_;
		my $nick = $act->{dst};
		return () if $act->{net} ne $net;

		if ($act->{killed}) {
			my @out = $net->_connect_ifo($nick);
			for my $chan (@{$act->{reconnect_chans}}) {
				next unless $chan->is_on($net);
				my $mode = join '', map {
					$chan->has_nmode($_, $nick) ? ($txt2pfx[$$net]{$_} || '') : ''
				} qw/voice halfop op admin owner/;
				push @out, $net->ncmd(FJOIN => $chan, $chan->ts(), $mode.','.$nick->str($net));
			}
			return @out;
		} else {
			return $net->cmd2($act->{from}, NICK => $act->{to});
		}
	}, NICK => sub {
		my($net,$act) = @_;
		my $id = $$net;
		$net->cmd2($act->{from}{$id}, NICK => $act->{to}{$id});
	}, UMODE => sub {
		my($net,$act) = @_;
		my @out;
		my $mode = $net->umode_to_irc($act->{mode}, $act->{dst}, \@out);
		unshift @out, $net->cmd2($act->{dst}, MODE => $act->{dst}, $mode) if $mode;
		@out;
	}, QUIT => sub {
		my($net,$act) = @_;
		return () if $act->{netsplit_quit};
		return () unless $act->{dst}->is_on($net);
		$net->cmd2($act->{dst}, QUIT => $act->{msg});
	}, JOIN => sub {
		my($net,$act) = @_;
		my $chan = $act->{dst};
		if ($act->{src}->homenet() eq $net) {
			Log::err_in($net, "Trying to force channel join remotely (".$act->{src}->gid().$chan->str($net).")");
			return ();
		}
		my $mode = '';
		if ($act->{mode}) {
			$mode .= ($txt2pfx[$$net]{$_} || '') for keys %{$act->{mode}};
		}
		$net->ncmd(FJOIN => $chan, $chan->ts(), $mode.','.$net->_out($act->{src}));
	}, PART => sub {
		my($net,$act) = @_;
		$net->cmd2($act->{src}, PART => $act->{dst}, $act->{msg});
	}, KICK => sub {
		my($net,$act) = @_;
		$net->cmd2($act->{src}, KICK => $act->{dst}, $act->{kickee}, $act->{msg});
	}, INVITE => sub {
		my($net,$act) = @_;
		$net->cmd2($act->{src}, INVITE => $act->{dst}, $act->{to});
	}, KILL => sub {
		my($net,$act) = @_;
		my $killfrom = $act->{net};
		return () unless $net eq $killfrom;
		return () unless defined $act->{dst}->str($net);
		$net->cmd2($act->{src}, KILL => $act->{dst}, $act->{msg});
	}, MODE => sub {
		my($net,$act) = @_;
		my $src = $act->{src} || $net;
		my $dst = $act->{dst};
		my @modes = $net->cmode_to_irc($dst, $act->{mode}, $act->{args}, $act->{dirs}, $capabs[$$net]{MAXMODES});
		my @out;
		for my $line (@modes) {
			push @out, $net->cmd2($src, FMODE => $dst, $dst->ts(), @$line);
		}
		@out;
	}, TOPIC => sub {
		my($net,$act) = @_;
		my $src = $act->{src};
		if ($src && $src->isa('Nick') && $src->is_on($net) && !$act->{in_link}) {
			return $net->cmd2($src, TOPIC => $act->{dst}, $act->{topic});
		}
		return $net->ncmd(FTOPIC => $act->{dst}, $act->{topicts}, $act->{topicset}, $act->{topic});
	}, NICKINFO => sub {
		my($net,$act) = @_;
		if ($act->{item} eq 'vhost') {
			return $net->cmd2($act->{dst}, FHOST => $act->{value});
		} elsif ($act->{item} eq 'name') {
			return $net->cmd2($act->{dst}, FNAME => $act->{value});
		} elsif ($act->{item} eq 'away') {
			return $net->cmd2($act->{dst}, AWAY => defined $act->{value} ? $act->{value} : ());
		} elsif ($act->{item} eq 'opertype') {
			return () unless $act->{value};
			my $visible = Setting::get(oper_visibility => $net);
			return ($net->cmd2($act->{dst}, MODE => $act->{dst}, '-o')) unless $visible;
			my $mch = '-o';
			my $suffix = $visible < 3 ? ' (remote)' : '';
			if ($visible == 1) {
				$mch = '-o+H' if $net->hook('cmode_out', 'hideoper');
			}
			my $len = $net->nicklen() - length $suffix;
			my $type = substr($act->{value}, 0, $len).$suffix;
			$type =~ s/ /_/g;
			return (
				# workaround for heap corruption bug in older versions of inspircd
				# triggered by opering up a user twice
				$net->cmd2($act->{dst}, MODE => $act->{dst}, $mch),
				$net->cmd2($act->{dst}, OPERTYPE => $type),
			);
		}
		return ();
	}, CHANTSSYNC => sub {
		my($net,$act) = @_;
		my $chan = $act->{dst};
		my $ts = $act->{newts};

		my @out = $net->ncmd(FJOIN => $chan, $ts, ','.$net->_out($Interface::janus));

		push @out, map {
			$net->ncmd(FMODE => $chan, $ts, @$_);
		} $net->cmode_to_irc($chan, Modes::delta(undef, $chan, $net, 1), $capabs[$$net]{MAXMODES});

		@out;
	}, CHANBURST => sub {
		my($net,$act) = @_;
		my $old = $act->{before};
		my $new = $act->{after};
		my @out;
		push @out, $net->ncmd(FJOIN => $new, $new->ts, ','.$net->_out($Interface::janus));
		push @out, map {
			$net->ncmd(FMODE => $new, $new->ts, @$_);
		} $net->cmode_to_irc($new, Modes::delta($new->ts < $old->ts ? undef : $old, $new), $capabs[$$net]{MAXMODES});
		if ($new->topic && (!$old->topic || $old->topic ne $new->topic)) {
			push @out, $net->ncmd(FTOPIC => $new, $new->topicts, $new->topicset, $new->topic);
		}
		@out;
	}, CHANALLSYNC => sub {
		my($net,$act) = @_;
		my $chan = $act->{chan};
		my @out;
		my $fj = '';
		# TODO this likely misses +qa if people turn off prefix mode for them
		for my $nick ($chan->all_nicks) {
			my $mode = $chan->get_nmode($nick);
			my $m = join '', map { $txt2pfx[$$net]{$_} || '' } keys %$mode;
			$fj .= ' '.$m.','.$net->_out($nick);
		}
		$fj =~ s/^ // or return ();
		push @out, $net->ncmd(FJOIN => $chan, $chan->ts, $fj);
		push @out, map {
			$net->ncmd(FMODE => $chan, $chan->ts, @$_);
		} $net->cmode_to_irc($chan, Modes::delta(undef, $chan), $capabs[$$net]{MAXMODES});
		if ($chan->topic) {
			push @out, $net->ncmd(FTOPIC => $chan, $chan->topicts, $chan->topicset, $chan->topic);
		}
		@out;
	}, MSG => sub {
		my($net,$act) = @_;
		return if $act->{dst}->isa('Network');
		my $type = $act->{msgtype} || 'PRIVMSG';
		my $dst = ($act->{prefix} || '').$net->_out($act->{dst});
		if ($type eq '317') {
			my @msg = @{$act->{msg}};
			return () unless @msg >= 3;
			return $net->cmd2($msg[0], IDLE => $act->{dst}, $msg[2], $msg[1]);
		} elsif ($type =~ /^[356789]\d\d$/) {
			# assume this is part of a WHOIS reply; discard
			return ();
		}
		if (($type eq 'PRIVMSG' || $type eq 'NOTICE') && $act->{src}->isa('Nick') && $act->{src}->is_on($net)) {
			return $net->cmd2($act->{src}, $type, $dst, $act->{msg});
		} elsif ($act->{dst}->isa('Nick')) {
			# sent to a single user - it's easier to just PUSH the result
			my $msg = $net->cmd2($act->{src}, $type, $dst, ref $act->{msg} eq 'ARRAY' ? @{$act->{msg}} : $act->{msg});
			return $net->ncmd(PUSH => $act->{dst}, $msg);
		} elsif ($type eq 'PRIVMSG' || $type eq 'NOTICE') {
			# main case: people speaking in -n channels; a bunch of race conditions also come here
			# TODO this should be improved by m_janus.so if it gets written
			my $msg = $act->{msg};
			my $src = $act->{src};
			$src = $src->homenick . '/' . $src->homenet->name if $src && $src->isa('Nick');
			$msg = $msg =~ /^\001ACTION (.*?)\001?$/ ? '* '.$net->_out($src).' '.$msg : '<'.$net->_out($src).'> '.$msg;
			return $net->cmd2($Interface::janus, $type, $dst, $msg);
		}
		return ();
	}, WHOIS => sub {
		my($net,$act) = @_;
		$net->cmd2($act->{src}, IDLE => $act->{dst});
	}, PING => sub {
		my($net,$act) = @_;
		$net->ncmd(PING => $servers[$$net]{''});
	}, RAW => sub {
		my($net,$act) = @_;
		$act->{msg};
	},
}};

Event::hook_add(
	INFO => 'Network:1' => sub {
		my($dst, $net, $asker) = @_;
		return unless $net->isa(__PACKAGE__);
		Janus::jmsg($dst, 'Server CAP line: '.join ' ', sort map
			"$_=$capabs[$$net]{$_}", keys %{$capabs[$$net]});
		Janus::jmsg($dst, 'Modules: '. join ' ', sort $net->all_modules);
		# TODO maybe server list?
	},
	Server => find_module => sub {
		my($net, $name, $d) = @_;
		return unless $net->isa(__PACKAGE__);
		return unless $moddef{$name};
		$$d = $moddef{$name};
	}
);

1;
