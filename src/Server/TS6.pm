# Copyright (C) 2007-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Server::TS6;
use Nick;
use Modes;
use Server::BaseUID;
use Server::ModularNetwork;

use Persist 'Server::BaseUID', 'Server::ModularNetwork';
use strict;
use warnings;
use integer;

our(@sendq, @servers, @serverdsc, @servernum, @next_uid, @capabs);
Persist::register_vars(qw(sendq servers serverdsc servernum next_uid capabs));

sub _init {
	my $net = shift;
	$sendq[$$net] = '';
	$net->module_add('CORE');
}

sub ignore { () }

sub nick_msg {
	my $net = shift;
	my $src = $net->item($_[0]);
	my $msg = [ @_[3..$#_] ];
	my $about = $net->item($_[3]);
	$about ||= $net->nick($_[3], 1);
	if (ref $about && $about->isa('Nick')) {
		$msg->[0] = $about;
	}
	if ($_[2] =~ /\./) {
		Log::warn_in($net, 'numeric', @_);
		return ();
	}
	my $dst = $net->nick($_[2]) or return ();
	return {
		type => 'MSG',
		src => $src,
		dst => $dst,
		msg => $msg,
		msgtype => $_[1],
	};
}

sub nicklen {
	15 # TODO any way to tell?
}

sub str {
	my $net = shift;
	$net->jname();
}

sub intro {
	my($net,@param) = @_;
	$net->SUPER::intro(@param);
	my $sep = Setting::get(tagsep => $net);
	Setting::set(tagsep => $net, '_') if $sep eq '/';
	my $ircd = $net->cparam('ircd');
	if ($ircd) {
		$net->module_add(uc $ircd, 1);
	}
	if ($net->auth_should_send) {
		my $name = $net->cparam('linkname') || $RemoteJanus::self->jname;
		$net->send(
			$net->cmd2(undef, PASS => $net->cparam('sendpass'),'TS',6,$net),
# TODO goal 'CAPAB :QS EX CHW IE KLN EOB HOPS HUB KNOCK TB UNKLN CLUSTER ENCAP SERVICES RSFNC SAVE EUID',
			'CAPAB :QS EX CHW IE EOB HOPS HUB KNOCK TB CLUSTER ENCAP SERVICES SAVE EUID',
			$net->cmd2(undef, SERVER => $name, 0, 'Janus Network Link'),
			'SVINFO 6 6 0 '.$Janus::time,
		);
	}
}

# parse one line of input
sub parse {
	my ($net, $line) = @_;
	my ($txt, $msg) = split /\s+:/, $line, 2;
	my @args = split /\s+/, $txt;
	push @args, $msg if defined $msg;
	if ($args[0] !~ s/^://) {
		unshift @args, undef;
	}
	my $cmd = $args[1];
	Log::netin(@_) unless $cmd eq 'PRIVMSG' || $cmd eq 'NOTICE';
	unless ($net->auth_ok || $cmd eq 'PASS' || $cmd eq 'SERVER' || $cmd eq 'CAPAB' || $cmd eq 'ERROR') {
		return () if $cmd eq 'NOTICE'; # NOTICE AUTH ... annoying
		$sendq[$$net] .= "ERROR :Not authorized yet\r\n";
		return ();
	}
	return $net->nick_msg(@args) if $cmd =~ /^\d+$/;
	$net->from_irc(@args);
}

sub send {
	my $net = shift;
	my @q = $net->to_irc(@_);
	$sendq[$$net] .= join '', map "$_\r\n", @q;
}

sub dump_sendq {
	my $net = shift;
	local $_;
	my $q = $sendq[$$net];
	$sendq[$$net] = '';
	Log::netout($net, $_) for split /\r\n/, $q;
	$q;
}

my @letters = ('A' .. 'Z', 0 .. 9);

sub net2uid {
	return '0AJ' if @_ == 2 && $_[0] == $_[1];
	my $srv = $_[-1];
	my $snum = $$srv - 2;
	return '0AJ' if $snum <= 0; # Interface, RemoteJanus::self are #1,2
	my $res = ($snum / 36) . $letters[$snum % 36] . 'J';
	warn 'you have too many servers' if length $res > 3;
		# maximum of 360. Can be increased if 'J' is modified too
	$res;
}

sub next_uid {
	my($net, $srv) = @_;
	my $pfx = net2uid($srv);
	my $number = $next_uid[$$net]{$pfx}++;
	my $uid = '';
	for (1..6) {
		$uid = $letters[$number % 36].$uid;
		$number /= 36;
	}
	warn if $number; # wow, you had 2 billion users on this server?
	$pfx.$uid;
}

# IRC Parser
# Arguments:
#	$_[0] = Network
#	$_[1] = source (not including leading ':') or 'undef'
#	$_[2] = command (for multipurpose subs)
#	3 ... = arguments to the irc line; last element has the leading ':' stripped
# Return:
#  list of hashrefs containing the Action(s) represented (can be empty)

sub _out {
	my($net,$itm) = @_;
	return '' unless defined $itm;
	return $itm unless ref $itm;
	if ($itm->isa('Nick')) {
		my $rv;
		$rv = $net->nick2uid($itm) if $itm->is_on($net);
		$rv = $net->net2uid($itm->homenet()) unless defined $rv;
		return $rv;
	} elsif ($itm->isa('Channel')) {
		return $itm->str($net);
	} elsif ($itm->isa('Network') || $itm->isa('RemoteJanus')) {
		return $net->net2uid($itm);
	} else {
		Log::err_in($net, "Unknown item $itm");
		return $net->net2uid($net);
	}
}

sub ncmd {
	my $net = shift;
	$net->cmd2($net, @_);
}

sub cmd2 {
	my($net,$src,$cmd) = (shift,shift,shift);
	my $out = defined $src ? ':'.$net->_out($src).' ' : '';
	$out .= $cmd;
	if (@_) {
		my $end = $net->_out(pop @_);
		$out .= ' '.$net->_out($_) for @_;
		$out .= ' :'.$end;
	}
	$out;
}

our %moddef = ();
Janus::static('moddef');
$moddef{CAPAB_HOPS} = { cmode => { h => 'n_halfop' } };
$moddef{CAPAB_EX} = { cmode => { e => 'l_except' } };
$moddef{CAPAB_IE} = { cmode => { I => 'l_invex' } };
$moddef{CAPAB_TB} = {
	cmds => {
		TB => sub {
			my $net = shift;
			my $src = $net->item($_[0]);
			my $chan = $net->chan($_[2]) or return ();
			return +{
				type => 'TOPIC',
				src => $src,
				dst => $chan,
				topicts => $_[3],
				topicset => (@_ == 6 ? $_[4] : $src && $src->isa('Nick') ? $src->homenick() : 'janus'),
				topic => $_[-1],
			};
		},
	}, acts => {
		CHANBURST => sub {
			my($net,$act) = @_;
			my $old = $act->{before};
			my $new = $act->{after};
			my @sjmodes = Modes::to_irc($net, Modes::dump($new));
			@sjmodes = '+' unless @sjmodes;
			my @out;
			push @out, $net->ncmd(SJOIN => $new->ts, $new, @sjmodes, $net->_out($Interface::janus));
			push @out, map {
				$net->ncmd(TMODE => $new->ts, $new, @$_);
			} Modes::to_multi($net, Modes::delta($new->ts < $old->ts ? undef : $old, $new), 10);
			if ($new->topic && (!$old->topic || $old->topic ne $new->topic)) {
				push @out, $net->ncmd(TB => $new, $new->topicts, $new->topicset, $new->topic);
			}
			@out;
		}, CHANALLSYNC => sub {
			my($net,$act) = @_;
			my $chan = $act->{chan};
			my @sjmodes = Modes::to_irc($net, Modes::dump($chan));
			@sjmodes = '+' unless @sjmodes;
			my @out;
			my $fj = '';
			for my $nick ($chan->all_nicks) {
				my $mode = $chan->get_nmode($nick);
				my $m = join '', map { $net->txt2cmode("n_$_") || '' } keys %$mode;
				$fj .= ' '.$m.$net->_out($nick);
			}
			$fj =~ s/^ // or return ();
			push @out, $net->ncmd(SJOIN => $chan->ts, $chan, @sjmodes, $fj);
			push @out, map {
				$net->ncmd(TMODE => $chan->ts, $chan, @$_);
			} Modes::to_multi($net, Modes::delta(undef, $chan), 10);
			if ($chan->topic) {
				push @out, $net->ncmd(TB => $chan, $chan->topicts, $chan->topicset, $chan->topic);
			}
			@out;
		},
		TOPIC => sub {
			my($net,$act) = @_;
			my $src = $act->{src};
			if ($src && $src->isa('Nick') && $src->is_on($net)) {
				return $net->cmd2($src, TOPIC => $act->{dst}, $act->{topic});
			} else {
				return $net->ncmd(TB => $act->{dst}, $act->{topicts}, $act->{topicset}, $act->{topic});
			}
		},
	}
};
$moddef{CAPAB_EUID} = {
	acts => {
		CONNECT => sub {
			my($net,$act) = @_;
			my $nick = $act->{dst};
			return () if $act->{net} != $net;
			my @out;

			my $mode = '+';
			for my $m ($nick->umodes()) {
				my $um = $net->txt2umode($m);
				next unless defined $um;
				$mode .= $um;
			}

			my $ip = $nick->info('ip') || '0.0.0.0';
			$ip = '0.0.0.0' if $ip eq '*' || $net->param('untrusted');
			push @out, $net->cmd2($nick, AWAY => $nick->info('away')) if $nick->info('away');
			my $host = $nick->info($net->param('untrusted') ? 'vhost' : 'host');
			unshift @out, $net->cmd2($nick->homenet, EUID => $nick->str($net), 1, $nick->ts,
				$mode, $nick->info('ident'), $nick->info('vhost'), $ip, $nick, $host, 0, $nick->info('name'));

			@out;
		}
	},
};
$moddef{NOCAP_EUID} = {
	acts => {
		CONNECT => sub {
			my($net,$act) = @_;
			my $nick = $act->{dst};
			return () if $act->{net} != $net;
			my @out;

			my $mode = '+';
			for my $m ($nick->umodes()) {
				my $um = $net->txt2umode($m);
				next unless defined $um;
				$mode .= $um;
			}

			my $ip = $nick->info('ip') || '0.0.0.0';
			$ip = '0.0.0.0' if $ip eq '*' || $net->param('untrusted');
			push @out, $net->cmd2($nick, AWAY => $nick->info('away')) if $nick->info('away');
			unshift @out, $net->cmd2($nick->homenet, UID => $nick->str($net), 1, $nick->ts,
				$mode, $nick->info('ident'), $nick->info('vhost'), $ip, $nick, $nick->info('name'));

			@out;
		}
	},
};

$moddef{CAPAB_SAVE} = {
	cmds => {
		SAVE => sub {
			my $net = shift;
			my $nick = $net->nick($_[2]) or return ();
			return () unless $nick->ts == $_[3];
			if ($nick->homenet == $net) {
				Log::debug_in($net, "Misdirected SAVE ignored");
				return ();
			} else {
				return +{
					type => 'RECONNECT',
					src => $net->item($_[0]),
					dst => $nick,
					net => $net,
					killed => 0,
					altnick => 1,
				};
			}
		}
	}
};

$moddef{CHARYBDIS} = {
	cmode => {
		q => 'l_quiet',
		f => 's_forward',
		j => 's_joinlimit',
		F => 'r_', # can be +f target
		L => 'r_', # large ban lists
		P => 'r_permanent',
		Q => 'r_', # ignore forwards
		c => 'r_colorblock',
		g => 'r_allinvite',
		z => 'r_survey',
	},
	umode => {
		Z => 'ssl',
		Q => '',
		R => '',
		g => '',
		l => '',
		s => '',
		z => '',
	},
	cmds => {
		CHGHOST => sub {
			my $net = shift;
			my $src = $net->item($_[0]);
			my $dst = $net->nick($_[2]) or return ();
			if ($dst->homenet == $net) {
				return +{
					type => 'NICKINFO',
					src => $src,
					dst => $dst,
					item => 'vhost',
					value => $_[3],
				};
			} else {
				$net->send($net->cmd2($Interface::janus, CHGHOST => $_[2], $dst->info('vhost')));
				();
			}
		},
		PRIVS => \&ignore,
		REALHOST => sub {
			my $net = shift;
			my $nick = $net->mynick($_[0]) or return ();
			return +{
				type => 'NICKINFO',
				dst => $nick,
				item => 'host',
				value => $_[2],
			},
		},
		REHASH => \&ignore,
		SASL => \&ignore,
		SNOTE => \&ignore,
		SVSLOGIN => \&ignore,

# TODO:
		DLINE => \&ignore,
		NICKDELAY => \&ignore, # act like SVSNICK?
		UNDLINE => \&ignore,
	},
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
		r => 'r_reginvite',
		's' => 't2_chanhide',
		t => 'r_topic',
		v => 'n_voice',
  },
  umode => {
		D => 'deaf_chan',
		S => 'service',
		a => 'admin',
		i => 'invisible',
		o => 'oper',
		w => 'wallops',
  },
  cmds => {
	ADMIN => \&ignore,
	AWAY => sub {
		my $net = shift;
		my $nick = $net->mynick($_[0]) or return ();
		return +{
			dst => $nick,
			type => 'NICKINFO',
			item => 'away',
			value => $_[2],
		};
	},
	BMASK => \&ignore, # TODO
	CAPAB => sub {
		my $net = shift;
		for (split /\s+/, $_[-1]) {
			$capabs[$$net]{$_}++;
			$net->module_add('CAPAB_'.$_, 1);
		}
		# We send: QS EX CHW IE KLN EOB HOPS HUB KNOCK TB UNKLN CLUSTER ENCAP SERVICES RSFNC SAVE EUID
		# We require: (second list can be eliminated)
		for (qw/QS ENCAP  CHW TB/) {
			next if $capabs[$$net]{$_};
			Log::err_in($net, "Cannot reliably link: CAPAB $_ not supported");
		}
		# We will be able to emulate:
		for (qw/TB EUID/) {
			next if $capabs[$$net]{$_};
			$net->module_add('NOCAP_'.$_);
		}
		();
	},
	CONNECT => \&ignore,
	ENCAP => sub {
		my($net,$src,undef,$dst,@args) = @_;
		# TODO check the dst mask
		$net->from_irc($src, @args);
	},
	ERROR => sub {
		my $net = shift;
		{
			type => 'NETSPLIT',
			net => $net,
			msg => 'ERROR: '.$_[-1],
		};
	},
	ETRACE => \&ignore,
	EUID => sub {
		my $net = shift;
		my $srvname = $servernum[$$net]{$_[0]} || $_[0];
		my %nick = (
			net => $net,
			nick => $_[2],
			ts => $_[4],
			info => {
				home_server => $srvname,
				ident => $_[6],
				vhost => $_[7],
				ip => $_[8],
				name => $_[-1],
			},
		);
		if ($_[1] eq 'EUID') {
			$nick{info}{host} = $_[10];
			$nick{info}{svsaccount} = $_[11] if $_[11] ne '0';
		} else {
			$nick{info}{host} = $_[7];
		}
		my @m = split //, $_[5];
		warn unless '+' eq shift @m;
		$nick{mode} = +{ map {
			my $t = $net->umode2txt($_);
			$t ? ($t => 1) : ();
		} @m };
		my $nick = Nick->new(%nick);
		$net->register_nick($nick, $_[9]);
	},
	GCAP => \&ignore,
	INFO => \&ignore,
	INVITE => sub {
		my $net = shift;
		my $src = $net->mynick($_[0]) or return ();
		my $dst = $net->nick($_[2]) or return ();
		my $chan = $net->chan($_[3]) or return ();
		if ($_[4] && $_[4] != $chan->ts) {
			return ();
		}
		return {
			type => 'INVITE',
			src => $src,
			dst => $dst,
			to => $chan,
			timeout => $_[4],
		};
	},
	JOIN => sub {
		my $net = shift;
		my $nick = $net->mynick($_[0]) or return ();
		my @act;
		if ($_[2] eq '0') {
			# this is SUCH a dumb feature...
			@act = ();
			for my $c ($nick->all_chans()) {
				push @act, +{
					type => 'PART',
					src => $nick,
					dst => $c,
					msg => 'Left all channels',
				};
			}
		} else {
			my $chan = $net->chan($_[3], $_[2]);
			if ($chan->ts > $_[2]) {
				my $syncact = +{
					type => 'CHANTSSYNC',
					src => $net,
					dst => $chan,
					newts => $_[2],
					oldts => $chan->ts(),
				};
				push @act, $syncact;
				if ($chan->homenet == $net) {
					my($modes,$args,$dirs) = Modes::dump($chan);
					# this is a TS wipe, justified. Wipe janus's side.
					$_ = '-' for @$dirs;
					push @act, +{
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
			push @act, +{
				type => 'JOIN',
				src => $nick,
				dst => $chan,
			};
		}
		@act;
	},
	KICK => sub {
		my $net = shift;
		my $nick = $net->nick($_[3]) or return ();
		return {
			type => 'KICK',
			src => $net->item($_[0]),
			dst => $net->chan($_[2]),
			kickee => $nick,
			msg => $_[4],
		};
	},
	KILL => sub {
		my $net = shift;
		my $src = $net->item($_[0]);
		my $dst = $net->nick($_[2]) or return ();
		my $msg = $_[3];

		if ($dst->homenet == $net) {
			return {
				type => 'QUIT',
				dst => $dst,
				msg => $msg,
				killer => $src,
			};
		}
		return {
			type => 'KILL',
			src => $src,
			dst => $dst,
			net => $net,
			msg => $msg,
		};
	},
	KLINE => \&ignore,
	KNOCK => \&ignore,
	LINKS => \&ignore,
	LOCOPS => \&ignore,
	LOGIN => sub {
		my $net = shift;
		my $nick = $net->mynick($_[0]) or return ();
		return +{
			type => 'NICKINFO',
			dst => $nick,
			item => 'svsaccount',
			value => $_[2],
		}, +{
			type => 'UMODE',
			dst => $nick,
			mode => [ '+registered' ],
		};
	},
	LUSERS => \&ignore,
	MODE => sub {
		my $net = shift;
		my $src = $net->item($_[0]) or return ();
		my $chan = $net->item($_[2]) or return ();
		if ($chan->isa('Nick')) {
			# umode change
			return () unless $chan->homenet() eq $net;
			return $net->_parse_umode($chan, @_[3 .. $#_]);
		}
		my $mode = $_[3];
		my($modes,$args,$dirs) = Modes::from_irc($net, $chan, $mode, @_[4 .. $#_]);
		return {
			type => 'MODE',
			src => $src,
			dst => $chan,
			mode => $modes,
			args => $args,
			dirs => $dirs,
		};
	},
	MOTD => \&ignore,
	NICK => sub {
		my $net = shift;
		my $nick = $net->mynick($_[0]) or return ();
		my $stomp = $net->nick($_[2], 1);
		my $ts = $_[3];
		unless ($ts) {
			Log::warn_in($net, 'Nick change without timestamp');
			$ts = $Janus::time;
		}
		my @out;
		if ($stomp && $stomp != $nick) {
			push @out, +{
				type => 'RECONNECT',
				dst => $stomp,
				net => $net,
				altnick => 1,
				killed => 0,
			};
		}
		push @out, {
			type => 'NICK',
			src => $nick,
			dst => $nick,
			nick => $_[2],
			nickts => $ts,
		};
		@out;
	},
	NOTICE => 'PRIVMSG',
	OPERSPY => \&ignore,
	OPERWALL => \&ignore,
	PART => sub {
		my $net = shift;
		return map +{
			type => 'PART',
			src => $net->mynick($_[0]),
			dst => $net->chan($_),
			msg => $_[3],
		}, split /,/, $_[2];
	},
	PASS => sub {
		my $net = shift;
		if ($_[2] eq $net->cparam('recvpass')) {
			$net->auth_recvd;
			if ($net->auth_should_send) {
				my $name = $net->cparam('linkname') || $RemoteJanus::self->jname;
				$net->send(
					$net->cmd2(undef, PASS => $net->cparam('sendpass'),'TS',6,$net),
					'CAPAB :QS EX CHW IE EOB HOPS HUB KNOCK TB CLUSTER ENCAP SERVICES SAVE EUID',
					$net->cmd2(undef, SERVER => $name, 0, 'Janus Network Link'),
					'SVINFO 6 6 0 '.$Janus::time,
				);
			}
			$servernum[$$net]{''} = $_[5];
		} else {
			$net->send('ERROR :Bad password');
		}
		();
	},
	PING => sub {
		my $net = shift;
		my $from = $_[3] || $net;
		$net->send($net->cmd2($from, 'PONG', $from, $_[2]));
		();
	},
	PONG => \&ignore,
	PRIVMSG => sub {
		my $net = shift;
		my $src = $net->item($_[0]);
		if ($_[2] =~ /^\$/ || $_[2] =~ /\@/) {
			# broadcast message. No action; these are confined to source net
			return ();
		} elsif ($_[2] =~ /([^#]?)(#\S*)/) {
			# channel message, possibly to a mode prefix
			my($pfx,$dst) = ($1,$net->chan($2));
			return {
				type => 'MSG',
				src => $src,
				prefix => $pfx,
				dst => $dst,
				msg => $_[3],
				msgtype => $_[1],
			} if $dst;
		} else {
			my $dst = $net->nick($_[2]);
			return +{
				type => 'MSG',
				src => $src,
				dst => $dst,
				msg => $_[3],
				msgtype => $_[1],
			} if $dst;
		}
	},
	QUIT => sub {
		my $net = shift;
		my $nick = $net->mynick($_[0]) or return ();
		return +{
			type => 'QUIT',
			dst => $nick,
			msg => $_[-1],
		};
	},
	RESV => \&ignore, # TODO
	RSFNC => \&ignore, # TODO nick change
	SERVER => sub {
		my $net = shift;
		my $num = delete $servernum[$$net]{''};
		$servernum[$$net]{$_[2]} = $num;
		$serverdsc[$$net]{$_[2]} = $_[-1];
		{
			type => 'NETLINK',
			net => $net,
		}, {
			type => 'BURST',
			net => $net,
		}, {
			type => 'LINKED',
			net => $net,
		};
	},
	SID => sub {
		my $net = shift;
		Log::debug_in($net, "Introducing server $_[2] from $_[0] with numeric $_[4]");
		$servers[$$net]{lc $_[2]} = $_[0] =~ /^\d/ ? $servernum[$$net]{$_[0]} : lc $_[0];
		$serverdsc[$$net]{lc $_[2]} = $_[-1];
		$servernum[$$net]{$_[4]} = $_[2];
		return ();
		();
	},
	SIGNON => sub {
		my $net = shift;
		my $nick = $net->mynick($_[0]) or return ();
		my @out;
		if ($nick->str($net) ne $_[2]) {
			push @out, $net->from_irc($_[0], NICK => $_[2], $_[5]);
		}
		my @new = @_[3,4,6];
		my @itm = qw/ident vhost svsaccount/;
		for (0,1) {
			next if $nick->info($itm[$_]) eq $new[$_];
			push @out, {
				type => 'NICKINFO',
				src => $nick,
				dst => $nick,
				item => $itm[$_],
				value => $new[$_],
			};
		}
		@out;
	},
	SJOIN => sub {
		my $net = shift;
		my $ts = $_[2];
		my $chan = $net->chan($_[3], $ts);
		my $applied = ($chan->ts() >= $ts);
		my @acts;

		if ($chan->ts > $ts) {
			my $syncact = +{
				type => 'CHANTSSYNC',
				src => $net,
				dst => $chan,
				newts => $_[2],
				oldts => $chan->ts(),
			};
			push @acts, $syncact;
			if ($chan->homenet == $net) {
				my($modes,$args,$dirs) = Modes::dump($chan);
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

		my($modes,$args,$dirs,$users) = Modes::from_irc($net, $chan, @_[4 .. $#_]);
		if ($applied && @$dirs) {
			push @acts, +{
				type => 'MODE',
				src => $net,
				dst => $chan,
				mode => $modes,
				args => $args,
				dirs => $dirs,
			};
		}

		$users = '' unless defined $users;
		for my $nm (split / /, $users) {
			$nm =~ /^(\D*)(\S+)$/ or next;
			my $nmode = $1;
			my $nick = $net->mynick($2) or next;
			my %mh = map {
				tr/@%+/ohv/;
				$_ = $net->cmode2txt($_);
				/^n_(.+)/ ? ($1 => 1) : ();
			} split //, $nmode;
			push @acts, +{
				type => 'JOIN',
				src => $nick,
				dst => $chan,
				mode => ($applied ? \%mh : undef),
			};
		}
		@acts;
	},
	SQUIT => sub {
		my $net = shift;
		my $srv = $_[2];
		my $splitfrom = $servers[$$net]{lc $srv};

		my %sgone = (lc $srv => 1);
		my $k = 0;
		while ($k != scalar keys %sgone) {
			# loop to traverse each layer of the map
			$k = scalar keys %sgone;
			for (keys %{$servers[$$net]}) {
				$sgone{$_} = 1 if $sgone{$servers[$$net]{$_}};
			}
		}
		my @ksg = sort keys %sgone;
		Log::info_in($net, 'Lost servers: '.join(' ', @ksg));
		delete $servers[$$net]{$_} for @ksg;
		delete $serverdsc[$$net]{$_} for @ksg;
		for (keys %{$servernum[$$net]}) {
			$sgone{$_}++ if $sgone{$servernum[$$net]{$_}};
		}
		delete $servernum[$$net]{$_} for keys %sgone;

		my @quits;
		for my $nick ($net->all_nicks()) {
			next unless $nick->homenet() eq $net;
			next unless $sgone{lc $nick->info('home_server')};
			push @quits, +{
				type => 'QUIT',
				src => $net,
				dst => $nick,
				msg => "$splitfrom $srv",
			}
		}
		@quits;
	},
	STATS => \&ignore,
	SU => sub {
		my $net = shift;
		my $nick = $net->mynick($_[2]) or return ();
		return +{
			type => 'NICKINFO',
			src => $nick,
			dst => $nick,
			item => 'svsaccount',
			value => $_[3],
		};
	},
	SVINFO => sub {
		();
	},
	TIME => \&ignore,
	TMODE => sub {
		my $net = shift;
		my $src = $net->item($_[0]);
		my $chan = $net->chan($_[2]) or return ();
		my $ts = $_[3];
		return () if $ts > $chan->ts();
		my($modes,$args,$dirs) = Modes::from_irc($net, $chan, @_[4 .. $#_]);
		return +{
			type => 'MODE',
			src => $src,
			dst => $chan,
			mode => $modes,
			args => $args,
			dirs => $dirs,
		};
	},
	TOPIC => sub {
		my $net = shift;
		my $src = $net->item($_[0]);
		my $chan = $net->chan($_[2]) or return ();
		return +{
			type => 'TOPIC',
			src => $src,
			dst => $chan,
			topicts => $Janus::time,
			topicset => ($src && $src->isa('Nick') ? $src->homenick() : 'janus'),
			topic => $_[-1],
		};
	},
	TRACE => \&ignore,
	'UID' => 'EUID',
	UNKLINE => \&ignore,
	UNRESV => \&ignore,
	UNXLINE => \&ignore,
	USERS => \&ignore,
	VERSION => \&ignore,
	WALLOPS => \&ignore,
	WHOIS => sub {
		my $net = shift;
		+{
			type => 'WHOIS',
			src => $net->item($_[0]),
			dst => $net->nick($_[2]),
		}
	},
	XLINE => \&ignore,
  }, acts => {
	JNETLINK => sub {
		my($net,$act) = @_;
		my $new = $act->{net};
		my $jid = $new->id().'.janus';
		$net->ncmd(SID => $jid, 1, $new, 'Inter-Janus link');
	}, NETLINK => sub {
		my($net,$act) = @_;
		my $new = $act->{net};
		my @out;
		if ($net eq $new) {
			for my $ij (values %Janus::ijnets) {
				next unless $ij->is_linked();
				next if $ij eq $RemoteJanus::self;
				my $jid = $ij->id().'.janus';
				push @out, $net->ncmd(SID => $jid, 1, $ij, 'Inter-Janus link');
			}
			for my $id (keys %Janus::nets) {
				my $new = $Janus::nets{$id};
				next if $new->isa('Interface') || $new eq $net;
				my $jl = $new->jlink();
				if ($jl) {
					push @out, $net->cmd2($jl, SID => $new->jname(), 2, $new, $new->netname());
				} else {
					push @out, $net->ncmd(SID => $new->jname(), 1, $new, $new->netname());
				}
			}
		} else {
			my $jl = $new->jlink();
			if ($jl) {
				push @out, $net->cmd2($jl, SID => $new->jname(), 2, $new, $new->netname());
			} else {
				push @out, $net->ncmd(SID => $new->jname(), 1, $new, $new->netname());
			}
		}
		return @out;
	}, NETSPLIT => sub {
		my($net,$act) = @_;
		return () if $act->{netsplit_quit};
		my $gone = $act->{net};
		my $msg = $act->{msg} || 'Excessive Core Radiation';
		return (
			$net->ncmd(SQUIT => $gone->jname(), $msg),
		);
	}, JNETSPLIT => sub {
		my($net,$act) = @_;
		my $gone = $act->{net};
		my $jid = $gone->id().'.janus';
		my $msg = $act->{msg} || 'Excessive Core Radiation';
		return (
			$net->ncmd(SQUIT => $jid, $msg),
		);
	}, RECONNECT => sub {
		my($net,$act) = @_;
		my $nick = $act->{dst};
		return () if $act->{net} ne $net;

		if ($act->{killed}) {
			my @out = $net->to_irc({ type => 'CONNECT', nick => $nick, net => $net });
			for my $chan (@{$act->{reconnect_chans}}) {
				next unless $chan->is_on($net);
				my $mode = join '', map {
					$chan->has_nmode($_, $nick) ? ($net->txt2cmode("n_$_") || '') : ''
				} qw/voice halfop op/;
				$mode =~ tr/ohv/@%+/;
				my @cmodes = Modes::to_multi($net, Modes::dump($chan), 10);
				@cmodes = (['+']) unless @cmodes && @{$cmodes[0]};

				push @out, $net->ncmd(SJOIN => $chan->ts, $chan, @{$cmodes[0]}, $mode.$nick->str($net));
			}
			return @out;
		} else {
			return $net->cmd2($act->{dst}, NICK => $act->{to}, $nick->ts());
		}
	}, NICK => sub {
		my($net,$act) = @_;
		my $id = $$net;
		my $dst = $act->{dst};
		$net->cmd2($dst, NICK => $act->{to}{$id}, $dst->ts);
	}, UMODE => sub {
		my($net,$act) = @_;
		my $pm = '';
		my $mode = '';
		my @out;
		my @modearg;
		for my $ltxt (@{$act->{mode}}) {
			my($d,$txt) = $ltxt =~ /^([-+])(.+)/;
			my $um = $net->txt2umode($txt);
			if (ref $um) {
				$um = $um->($net, $act->{dst}, $ltxt, \@out, \@modearg);
			}
			if (defined $um && $um ne '') {
				$mode .= $d if $pm ne $d;
				$mode .= $um;
				$pm = $d;
			}
		}
		unshift @out, $net->cmd2($act->{dst}, MODE => $act->{dst}, $mode, @modearg) if $mode;
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
			Log::err_in($net,"Trying to force channel join remotely (".$act->{src}->gid().$chan->str($net).")");
			return ();
		}
		my $mode = '';
		if ($act->{mode}) {
			$mode .= ($net->txt2cmode("n_$_") || '') for keys %{$act->{mode}};
			$mode =~ tr/ohv/@%+/;
			my @cmodes = Modes::to_multi($net, Modes::dump($chan));
			@cmodes = (['+']) unless @cmodes && @{$cmodes[0]};
			return $net->ncmd(SJOIN => $chan->ts, $chan, @{$cmodes[0]}, $mode.$net->_out($act->{src}));
		} else {
			return $net->cmd2($act->{src}, JOIN => $chan->ts, $chan, '+');
		}
	}, PART => sub {
		my($net,$act) = @_;
		$net->cmd2($act->{src}, PART => $act->{dst}, $act->{msg});
	}, KICK => sub {
		my($net,$act) = @_;
		$net->cmd2($act->{src}, KICK => $act->{dst}, $act->{kickee}, $act->{msg});
	}, INVITE => sub {
		my($net,$act) = @_;
		$net->cmd2($act->{src}, INVITE => $act->{dst}, $act->{to}, $act->{timeout});
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
		my @modes = Modes::to_multi($net, $act->{mode}, $act->{args}, $act->{dirs}, 10);
		my @out;
		for my $line (@modes) {
			push @out, $net->cmd2($src, TMODE => $dst->ts, $dst, @$line);
		}
		@out;
	}, NICKINFO => sub {
		my($net,$act) = @_;
		my $nick = $act->{dst};
		if ($act->{item} eq 'away') {
			return $net->cmd2($nick, AWAY => defined $act->{value} ? $act->{value} : ());
		} elsif ($act->{item} =~ /^(?:vhost|ident)$/) {
			return $net->cmd2($nick, SIGNON => $nick->str($net), $nick->info('ident'),
				$nick->info('vhost'), $nick->ts, 0);
		}
		return ();
	}, CHANTSSYNC => sub {
		my($net,$act) = @_;
		my $chan = $act->{dst};
		my $ts = $act->{newts};

		my @out = $net->cmd2($Interface::janus, JOIN => $ts, $chan, '+');
		my($m1,$a1,$d1) = Modes::delta(undef, $chan);
		my($m2,$a2,$d2) = Modes::reops($chan);
		push @$m1, @$m2;
		push @$a1, @$a2;
		push @$d1, @$d2;

		push @out, map {
			$net->ncmd(TMODE => $ts, $chan, @$_);
		} Modes::to_multi($net, $m1, $a1, $d1, 10);

		@out;
	}, MSG => sub {
		my($net,$act) = @_;
		return if $act->{dst}->isa('Network');
		my $type = $act->{msgtype} || 'PRIVMSG';
		my $dst = ($act->{prefix} || '').$net->_out($act->{dst});
		return () unless $type eq 'PRIVMSG' || $type eq 'NOTICE' || $type =~ /^\d\d\d$/;
		return () if $type eq '378' && $net->param('untrusted');
		my @msg = ref $act->{msg} eq 'ARRAY' ? @{$act->{msg}} : $act->{msg};
		if (ref $msg[0] && $msg[0]->isa('Nick')) {
			$msg[0] = $msg[0]->str($net);
		}
		my $src = $act->{src};
		$src = $src->homenet if $src->isa('Nick') && !$src->is_on($net);
		return $net->cmd2($src, $type, $dst, @msg);
		return ();
	}, WHOIS => sub {
		my($net,$act) = @_;
		$net->cmd2($act->{src}, WHOIS => $act->{dst}, $act->{dst});
	}, PING => sub {
		my($net,$act) = @_;
		$net->ncmd(PING => $net);
	},
}};

Event::hook_add(
	INFO => 'Network:1' => sub {
		my($dst, $net, $asker) = @_;
		return unless $net->isa(__PACKAGE__);
		Janus::jmsg($dst, 'Modules: '. join ' ', sort $net->all_modules);
	},
	Server => find_module => sub {
		my($net, $name, $d) = @_;
		return unless $net->isa(__PACKAGE__);
		return unless $moddef{$name};
		$$d = $moddef{$name};
	}
);

1;
