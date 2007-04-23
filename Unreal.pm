package Unreal; {
use Object::InsideOut 'Network';
use strict;
use warnings;
use Nick;
use Interface;

my @sendq :Field;
my @srvname :Field;
my @servers :Field;

my %fromirc;
my %toirc;
my %cmd2token = (qw/
		PRIVMSG     !
		NICK        &
		SERVER      '
		TOPIC       )
		INVITE      *
		VERSION     +
		SQUIT       -
		KILL        .
		LINKS       0
		STATS       2
		HELP        4
		ERROR       5
		AWAY        6
		CONNECT     7
		PING        8
		PONG        9
		PASS        <
		TIME        >
		ADMIN       @
		SETHOST     AA
		NACHAT      AC
		SETIDENT    AD
		SETNAME     AE
		LAG         AF
		SDESC       AG
		KNOCK       AI
		CREDITS     AJ
		LICENSE     AK
		CHGHOST     AL
		RPING       AM
		RPONG       AN
		NETINFO     AO
		SENDUMODE   AP
		ADDMOTD     AQ
		ADDOMOTD    AR
		SVSMOTD     AS
		SMO         AU
		OPERMOTD    AV
		TSCTL       AW
		SAJOIN      AX
		SAPART      AY
		CHGIDENT    AZ
		NOTICE      B
		SWHOIS      BA
		SVSO        BB
		SVSFLINE    BC
		TKL         BD
		VHOST       BE
		BOTMOTD     BF
		HTM         BH
		DCCDENY     BI
		UNDCCDENY   BJ
		CHGNAME     BK
		SHUN        BL
		CYCLE       BP
		MODULE      BQ
		SVSNLINE    BR
		SVSPART     BT
		SVSLUSERS   BU
		SVSSNO      BV
		SVS2SNO     BW
		SVSJOIN     BX
		SVSSILENCE  Bs
		SVSWATCH    Bw
		JOIN        C
		PART        D
		LUSERS      E
		EOS         ES
		MOTD        F
		MODE        G
		KICK        H
		REHASH      O
		RESTART     P
		CLOSE       Q
		SENDSNO     Ss
		DNS         T
		TEMPSHUN    Tz
		SILENCE     U
		AKILL       V
		UNKLINE     X
		RAKILL      Y
		GLOBOPS     ]
		LOCOPS      ^
		PROTOCTL    _
		TRACE       b
		SQLINE      c
		UNSQLINE    d
		SVSNICK     e
		SVSNOOP     f
		SVSKILL     h
		SVSMODE     n
		SAMODE      o
		CHATOPS     p
		UNZLINE     r
		RULES       t
		MAP         u
		SVS2MODE    v
		DALINFO     w
		ADMINCHAT   x
		UMODE2      |
		SJOIN       ~
/,		INFO =>    '/',
		WHOIS =>   '#',
		QUIT =>    ',',
		WATCH =>   '`',
);

my %token2cmd;
$token2cmd{$cmd2token{$_}} = $_ for keys %cmd2token;

my %umode2txt = (qw/
	o oper
	O oper_local
	C coadmin
	A admin
	a svs_admin
	N netadmin
	S service
	H hideoper
	h helpop
	g globops
	W whois_notice

	B bot
	i invisible
	G badword
	p hide_chans
	q no_kick
	r registered
	s snomask
	t vhost
	v dcc_reject
	w wallops
	x vhost_x
	z ssl
	V webtv

	d deaf_chan
	R deaf_regpriv
	T deaf_ctcp
/);

my %txt2umode;
$txt2umode{$umode2txt{$_}} = $_ for keys %umode2txt;

# Text prefixes:
#  n - nick access level
#  l - list (bans)
#  v - value (key)
#  s - value-on-set (limit)
#  r - regular (moderate)

my %cmode2txt = (qw/
	v n_voice
	h n_halfop
	o n_op
	a n_admin
	q n_owner
	b l_ban
	c r_colorblock
	e l_except
	I l_invex
	f v_flood3.2
	i r_invite
	j s_joinlimit
	k v_key
	l s_limit
	m r_moderated
	n r_mustjoin
	p r_private
	r r_register
	s r_secret
	t r_topic
	z r_sslonly
	A r_operadmin
	C r_ctcpblock
	G r_badword
	M r_regmoderated
	L r_forward
	N r_norenick
	O r_oper
	Q r_nokick
	R r_reginvite
	S r_colorstrip
	T r_noticeblock
	V r_noinvite
	u r_auditorium
/);

my %txt2cmode;
$txt2cmode{$cmode2txt{$_}} = $_ for keys %cmode2txt;

sub cmode2txt {
	$cmode2txt{$_[1]};
}
sub txt2cmode {
	return '' if $_[1] eq 'r_register';
	$txt2cmode{$_[1]};
}

sub nicklen { 30 }

sub debug {
	print @_, "\n";
}

sub str {
	my $net = shift;
	$net->id().'.janus';
}

sub intro {
	my $net = shift;
	if ($net->cparam('incoming')) {
		die "sorry, not supported";
	}
	$net->send(
		'PASS :'.$net->cparam('linkpass'),
		'PROTOCTL NOQUIT TOKEN NICKv2 CLK NICKIP SJOIN SJOIN2 SJ3 VL NS UMODE2 TKLEXT SJB64',
		'SERVER '.$net->cparam('linkname').' 1 :U2309-hX6eE-'.$net->cparam('numeric').' Janus Network Link',
	);
}

# parse one line of input
sub parse {
	my ($net, $line) = @_;
	debug '     IN@'.$net->id().' '. $line;
	my ($txt, $msg) = split /\s+:/, $line, 2;
	my @args = split /\s+/, $txt;
	push @args, $msg if defined $msg;
	if ($args[0] =~ /^@(\S+)$/) {
		$args[0] = $net->srvname($1);
	} elsif ($args[0] !~ s/^://) {
		unshift @args, undef;
	}
	my $cmd = $args[1];
	$cmd = $args[1] = $token2cmd{$cmd} if exists $token2cmd{$cmd};
	return $net->nick_msg(@args) if $cmd =~ /^\d+$/;
	unless (exists $fromirc{$cmd}) {
		debug "Unknown command $cmd";
		return ();
	}
	$fromirc{$cmd}->($net,@args);
}

sub send {
	my $net = shift;
	my @out;
	for my $act (@_) {
		if (ref $act) {
			my $type = $act->{type};
			if (exists $toirc{$type}) {
				push @out, $toirc{$type}->($net, $act);
			} else {
				debug "Unknown action type '$type'";
			}
		} else {
			push @out, $act;
		}
	}
	debug '    OUT@'.$net->id().' '.$_ for @out;
	$sendq[$$net] .= "$_\r\n" for @out;
}

sub dump_sendq {
	my $net = shift;
	my $q = $sendq[$$net];
	$sendq[$$net] = '';
	$q;
}

# IRC Parser
# Arguments:
# 	$_[0] = Network
# 	$_[1] = source (not including leading ':') or 'undef'
# 	$_[2] = command (for multipurpose subs)
# 	3 ... = arguments to the irc line; last element has the leading ':' stripped
# Return:
#  list of hashrefs containing the Action(s) represented (can be empty)

sub nickact {
	#(SET|CHG)(HOST|IDENT|NAME)
	my $net = shift;
	my($type, $act) = (lc($_[1]) =~ /(SET|CHG)(HOST|IDENT|NAME)/i);
	$act =~ s/host/vhost/i;
	
	my($src,$dst);
	if ($type eq 'set') {
		$src = $dst = $net->nick($_[0]);
	} else {
		$src = $net->item($_[0]);
		$dst = $net->nick($_[2]);
	}

	if ($dst->homenet()->id() eq $net->id()) {
		my %a = (
			type => 'NICKINFO',
			src => $src,
			dst => $dst,
			item => lc $act,
			value => $_[-1],
		);
		if ($act eq 'vhost' && !($dst->has_mode('vhost') || $dst->has_mode('vhost_x'))) {
			return (\%a, +{
				type => 'UMODE',
				dst => $dst,
				mode => ['+vhost', '+vhost_x'],
			});
		} else {
			return \%a;
		}
	} else {
		my $old = $dst->info($act);
		$act =~ s/vhost/host/;
		$net->send($net->cmd2($dst, 'SET'.uc($act), $old));
		return ();
	}
}

sub ignore { (); }
sub todo { (); }

sub nick_msg {
	my $net = shift;
	return () if $_[2] eq 'AUTH' && $_[0] =~ /\./;
	my $src = $net->item($_[0]);
	my $msgtype = 
		$_[1] eq 'PRIVMSG' ? 1 :
		$_[1] eq 'NOTICE' ? 2 :
		$_[1] eq 'WHOIS' ? 3 : 
		0;
	if ($_[2] =~ /^\$/) {
		# server broadcast message. No action; these are confined to source net
		return ();
	} elsif ($_[2] =~ /([~&@%+]?)(#\S*)/) {
		# channel message, possibly to a mode prefix
		return {
			type => 'MSG',
			src => $src,
			prefix => $1,
			dst => $net->chan($2),
			msg => $_[3],
			msgtype => $msgtype,
		};
	} elsif ($_[2] =~ /^(\S+?)(@\S+)?$/) {
		# nick message, possibly with a server mask
		# server mask is ignored as the server is going to be wrong anyway
		my $dst = $net->nick($1);
		return () unless $dst;
		return {
			type => 'MSG',
			src => $src,
			dst => $dst,
			msg => $_[3],
			msgtype => $msgtype,
		};
	}
}

sub _parse_umode {
	my($net, $nick, $mode) = @_;
	my @mode;
	my $pm = '+';
	my $vh_pre = $nick->has_mode('vhost') ? 3 : $nick->has_mode('vhost_x') ? 1 : 0;
	my $vh_post = $vh_pre;
	for (split //, $mode) {
		if (/[-+]/) {
			$pm = $_;
		} elsif (/d/ && $_[3]) {
			# adjusts the services TS - which is restricted to the local network
		} else {
			my $txt = $umode2txt{$_};
			if ($txt eq 'vhost') {
				$vh_post = $pm eq '+' ? 3 : $vh_post & 1;
			} elsif ($txt eq 'vhost_x') {
				$vh_post = $pm eq '+' ? $vh_post | 1 : 0;
			}
			push @mode, $pm.$txt;
		}
	}
	my @out;
	push @out, +{
		type => 'UMODE',
		dst => $nick,
		mode => \@mode,
	} if @mode;

	if ($vh_pre != $vh_post) {
		warn if $vh_post > 1; #invalid
		my $vhost = $vh_post ? $nick->info('chost') : $nick->info('host');
		push @out,{
			type => 'NICKINFO',
			dst => $nick,
			item => 'host',
			value => $vhost,
		};
	}				
	@out;
}

my $unreal64_table = join '', 0 .. 9, 'A'..'Z', 'a'..'z', '{}';

sub sjbint {
	my $t = $_[1];
	return $t unless $t =~ s/^!//;
	local $_;
	my $v = 0;
	$v = 64*$v + index $unreal64_table, $_ for split //, $t;
	$v;
}

sub sjb64 {
	my $n = $_[1];
	my $b = '';
	while ($n) {
		$b = substr($unreal64_table, $n & 63, 1) . $b;
		$n = int($n / 64);
	}
	$_[2] ? $b : '!'.$b;
}
sub srvname {
	my($net,$num) = @_;
	return $srvname[$$net]{$num} if exists $srvname[$$net]{$num};
	return $num;
}

%fromirc = (
# User Operations
	NICK => sub {
		my $net = shift;
		if (@_ < 10) {
			# Nick Change
			my $nick = $net->nick($_[0]) or return ();
			return +{
				type => 'NICK',
				src => $nick,
				dst => $nick,
				nick => $_[2],
				nickts => (@_ == 4 ? $net->sjbint($_[3]) : time),
			};
		}
		# NICKv2 introduction
		my %nick = (
			net => $net,
			nick => $_[2],
			ts => $net->sjbint($_[4]),
			info => {
				#hopcount => $_[3],
				ident => $_[5],
				host => $_[6],
				vhost => $_[6],
				home_server => $net->srvname($_[7]),
				#servicests => $net->sjbint($_[8]),
				name => $_[-1],
			},
		);
		if (@_ >= 12) {
			my @m = split //, $_[9];
			warn unless '+' eq shift @m;
			$nick{mode} = +{ map { $umode2txt{$_} => 1 } @m };
			delete $nick{mode}{''};
			$nick{info}{vhost} = $_[10];
		}
		if (@_ >= 14) {
			$nick{info}{chost} = $_[11];
			$nick{info}{ip_64} = $_[12];
			local $_ = $_[12];
			if (s/=+//) {
				my $textip_table = join '', 'A'..'Z','a'..'z', 0 .. 9, '+/';
				s/(.)/sprintf '%06b', index $textip_table, $1/eg;
				if (length $_[12] == 8) { # IPv4
					s/(.{8})/sprintf '%d.', oct "0b$1"/eg;
					s/\.\d*$//;
				} elsif (length $_[12] == 24) { # IPv6
					s/(.{16})/sprintf '%x:', oct "0b$1"/eg;
					s/:[^:]*$//;
				}
			}
			$nick{info}{ip} = $_;
		} else {
			$nick{info}{chost} = 'unknown.cloaked';
		}
		
		unless ($nick{mode}{vhost}) {
			$nick{info}{vhost} = $nick{mode}{vhost_x} ? $nick{info}{chost} : $nick{info}{host};
		}

		my $nick = Nick->new(%nick);
		$net->nick_collide($_[2], $nick);
		();
	}, QUIT => sub {
		my $net = shift;
		my $nick = $net->nick($_[0]) or return ();
		if ($nick->homenet()->id() eq $net->id()) {
			# normal boring quit
			return +{
				type => 'QUIT',
				dst => $nick,
				msg => $_[2],
			};
		} else {
			# whoever decided this is how SVSKILL works... must have been insane
			$net->release_nick($_[0]);
			return +{
				type => 'CONNECT',
				dst => $nick,
				net => $net,
				reconnect => 1,
				nojlink => 1,
			};
		}
	}, KILL => sub {
		my $net = shift;
		my $src = $net->item($_[0]);
		my $dst = $net->nick($_[2]) or return ();
		my $msg = $_[3];
		$msg =~ s/^\S+!//;

		if ($dst->homenet()->id() eq $net->id()) {
			return {
				type => 'QUIT',
				dst => $dst,
				msg => "Killed ($msg)",
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
	}, SVSKILL => sub {
		my $net = shift;
		my $nick = $net->nick($_[2]) or return ();
		return () if $nick->homenet()->id() eq $net->id(); 
			# if local, wait for the QUIT that will be sent along in a second
		$net->send($net->cmd2($nick, QUIT => $_[3]));
		$net->release_nick(lc $_[2]);
		return +{
			type => 'CONNECT',
			dst => $nick,
			net => $net,
			reconnect => 1,
			nojlink => 1,
		};
	}, UMODE2 => sub {
		my $net = shift;
		my $nick = $net->nick($_[0]) or return ();
		$net->_parse_umode($nick, @_[2 .. $#_]);
	}, SVSMODE => sub {
		my $net = shift;
		my $nick = $net->nick($_[2]) or return ();
		if ($nick->homenet()->id() eq $net->id()) {
			return $net->_parse_umode($nick, @_[3 .. $#_]);
		} else {
			my $mode = $_[3];
			$mode =~ y/-+/+-/;
			$mode =~ s/d// if $_[4];
			$mode =~ s/[raAN]//g;
			$mode =~ s/[-+]+([-+]|$)/$1/g; # umode +r-i ==> -+i ==> +i
			$net->send($net->cmd2($nick, 'UMODE2', $mode)) if $mode;
			return ();
		}
	},
	SETIDENT => \&nickact,
	CHGIDENT => \&nickact,
	SETHOST => \&nickact,
	CHGHOST => \&nickact,
	SETNAME => \&nickact,
	CHGNAME => \&nickact,
	SWHOIS => sub {
		my $net = shift;
		my $nick = $net->nick($_[2]) or return ();
		return +{
			src => $net->item($_[0]),
			dst => $nick,
			type => 'NICKINFO',
			item => 'swhois',
			value => $_[3],
		};
	}, AWAY => sub {
		my $net = shift;
		my $nick = $net->nick($_[0]) or return ();
		return +{
			dst => $nick,
			type => 'NICKINFO',
			item => 'away',
			value => $_[2],
		};
	},
# Channel Actions
	JOIN => sub {
		my $net = shift;
		my $nick = $net->nick($_[0]) or return ();
		my @act;
		for (split /,/, $_[2]) {
			my $chan = $net->chan($_, 1);
			push @act, +{
				type => 'JOIN',
				src => $nick,
				dst => $chan,
			};
		}
		@act;
	}, SJOIN => sub {
		my $net = shift;
		my $chan = $net->chan($_[3], 1);
		$chan->timesync($net->sjbint($_[2]));
		my $joins = pop;

		my @acts;
		my $cmode = $_[4] || '+';

		for (split /\s+/, $joins) {
			if (/^([&"'])(.+)/) {
				$cmode .= $1;
				push @_, $2;
			} else {
				/^([*~@%+]*)(.+)/ or warn;
				my $nmode = $1;
				my $nick = $net->nick($2) or next;
				my %mh = map { tr/*~@%+/qaohv/; $net->cmode2txt($_) => 1 } split //, $nmode;
				push @acts, +{
					type => 'JOIN',
					src => $nick,
					dst => $chan,
					mode => \%mh,
				};
			}
		}
		$cmode =~ tr/&"'/beI/;
		my($modes,$args) = $net->_modeargs($cmode, @_[5 .. $#_]);
		push @acts, +{
			type => 'MODE',
			src => $net,
			dst => $chan,
			mode => $modes,
			args => $args, 
		} if @$modes;
		return @acts;
	}, PART => sub {
		my $net = shift;
		my $nick = $net->nick($_[0]) or return ();
		return {
			type => 'PART',
			src => $nick,
			dst => $net->chan($_[2]),
			msg => @_ ==4 ? $_[3] : '',
		};
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
	}, MODE => sub {
		my $net = shift;
		$_[3] =~ s/^&//; # mode bounces. Bounce away...
		my($modes,$args) = $net->_modeargs(@_[3 .. $#_]);
		return {
			type => 'MODE',
			src => $net->item($_[0]),
			dst => $net->item($_[2]),
			mode => $modes,
			args => $args,
		};
	}, TOPIC => sub {
		my $net = shift;
		my %act = (
			type => 'TOPIC',
			dst => $net->chan($_[2]),
			topic => $_[-1],
		);
		if (defined $_[0]) {
			my $src = $act{src} = $net->item($_[0]);
			$act{topicset} = $src->str($net);
		}
		$act{topicset} = $_[3] if @_ > 4;
		$act{topicts} = $net->sjbint($_[4]) if @_ > 5;
		\%act;
	},
	INVITE => \&todo,
	KNOCK => \&todo,

# Server actions
	SERVER => sub {
		my $net = shift;
		# :src SERVER name hopcount [numeric] description
		my $name = lc $_[2];
		my $desc = $_[-1];

		my $snum = $net->sjb64((@_ > 5          ? $_[4] : 
				($desc =~ s/^U\d+-\S+-(\d+) //) ? $1    : 0), 1);

		$servers[$$net]{$name} = {
			parent => lc ($_[0] || $net->cparam('linkname')),
			hops => $_[3],
			numeric => $snum,
		};
		$srvname[$$net]{$snum} = $name if $snum;

		();
	}, SQUIT => sub {
		my $net = shift;
		my $netid = $net->id();
		my $srv = $net->srvname($_[2]);
		my $splitfrom = $servers[$$net]{$srv}{parent};
		
		my %sgone = (lc $srv => 1);
		my $k = 0;
		while ($k != scalar keys %sgone) {
			# loop to traverse each layer of the map
			$k = scalar keys %sgone;
			for (keys %{$servers[$$net]}) {
				$sgone{$_} = 1 if $sgone{$servers[$$net]{$_}{parent}};
			}
		}
		delete $srvname[$$net]{$servers[$$net]{$_}{numeric}} for keys %sgone;
		delete $servers[$$net]{$_} for keys %sgone;

		my @quits;
		my $nicks = $net->_nicks();
		for my $nick (values %$nicks) {
			next unless $nick->homenet()->id() eq $netid;
			next unless $sgone{lc $nick->info('home_server')};
			push @quits, +{
				type => 'QUIT',
				src => $net,
				dst => $nick,
				msg => "$splitfrom $srv",
			}
		}
		@quits;
	}, PING => sub {
		my $net = shift;
		my $from = $_[3] || $net->cparam('linkname');
		$net->send($net->cmd1('PONG', $from, $_[2]));
		();
	},
	PONG => \&ignore,
	PASS => \&todo,
	NETINFO => \&ignore,
	PROTOCTL => sub {
		my $net = shift;
		shift;
		print join ' ', @_, "\n";
		();
	}, EOS => sub {
		my $net = shift;
		my $srv = $_[0];
		if ($servers[$$net]{lc $srv}{parent} eq lc $net->cparam('linkname')) {
			return +{
				type => 'LINKED',
				net => $net,
				sendto => [],
			};
		}
		();
	},

# Messages
	PRIVMSG => \&nick_msg,
	NOTICE => \&nick_msg,
	WHOIS => \&nick_msg,
	HELP => \&ignore,
	SMO => \&ignore,
	SENDSNO => \&ignore,
	SENDUMODE => \&ignore,
	GLOBOPS => \&ignore,
	WALLOPS => \&ignore,
	CHATOPS => \&ignore,
	NACHAT => \&ignore,
	ADMINCHAT => \&ignore,
	
	TKL => sub {
		my $net = shift;
		my $iexpr;
		if ($_[3] eq 'G') {
			return unless $net->param('translate_gline');
			$iexpr = '*!'.$_[4].'@'.$_[5].'%*';
		} elsif ($_[3] eq 'Q') {
			return unless $net->param('translate_qline');
			$iexpr = $_[5].'!*';
		}
		return unless $iexpr;
		my $expr = &Interface::banify($iexpr);
		if ($_[2] eq '+') {
			$net->add_ban(+{
				expr => $expr,
				ircexpr => $iexpr,
				setter => $_[6],
				expire => $_[7],
				# 8 = set time
				reason => $_[9],
			});
		} else {
			$net->del_ban($expr);
		}
		();
	},
	SVSFLINE => \&ignore,
	TEMPSHUN => \&ignore,

	SAJOIN => \&ignore,
	SAPART => \&ignore,
	SVSJOIN => \&ignore,
	SVSLUSERS => \&ignore,
	SVSNICK => \&ignore,
	SVSNOOP => \&ignore,
	SVSO => \&ignore,
	SVSSILENCE => \&ignore,
	SVSPART => \&ignore,
	SVSSNO => \&ignore,
	SVS2SNO => \&ignore,
	SVSWATCH => \&ignore,
	SQLINE => \&ignore,
	UNSQLINE => \&ignore,

	VERSION => \&todo,
	CREDITS => \&todo,
	DALINFO => \&todo,
	LICENSE => \&todo,
	ADMIN => \&todo,
	LINKS => \&todo,
	STATS => \&todo,
	MODULE => \&todo,
	MOTD => \&todo,
	RULES => \&todo,
	LUSERS => \&todo,
	ADDMOTD => \&todo,
	ADDOMOTD => \&todo,
	SVSMOTD => \&todo,
	OPERMOTD => \&todo,
	BOTMOTD => \&todo,
	INFO => \&todo,
	TSCTL => \&todo,
	TIME => \&todo,
	LAG => \&todo,
	TRACE => \&todo,
	RPING => \&todo,
	RPONG => \&todo,
	ERROR => \&todo,
	CONNECT => \&todo,
	SDESC => \&todo,
	HTM => \&todo,
	REHASH => \&todo,
	RESTART => \&todo,
);
$fromirc{SVS2MODE} = $fromirc{SVSMODE};

sub _out {
	my($net,$itm) = @_;
	return '' unless defined $itm;
	return $itm unless ref $itm;
	if ($itm->isa('Nick')) {
		return $itm->str($net) if $itm->is_on($net);
		return $itm->homenet()->id() . '.janus';
	} elsif ($itm->isa('Channel')) {
		warn "This channel message must have been misrouted: ".$itm->keyname() 
			unless $itm->is_on($net);
		return $itm->str($net);
	} elsif ($itm->isa('Network')) {
		return $itm->id(). '.janus';
	} else {
		warn "Unknown item $itm";
		$net->cparam('linkname');
	}
}

sub cmd1 {
	my $net = shift;
	$net->cmd2(undef, @_);
}

sub cmd2 {
	my($net,$src,$cmd) = (shift,shift,shift);
	my $out = defined $src ? ':'.$net->_out($src).' ' : '';
	$out .= $cmd2token{$cmd};
	if (@_) {
		my $end = $net->_out(pop @_);
		$out .= ' '.$net->_out($_) for @_;
		$out .= ' :'.$end;
	}
	$out;
}

%toirc = (
	NETLINK => sub {
		my($net,$act) = @_;
		my $new = $act->{net};
		my $id = $new->id();
		my @out;
		push @out, $net->cmd1(SMO => 'o', "(\002link\002) Janus Network $id (".$new->netname().") is now linked");
		if ($net->id() eq $id) {
			# first link to the net
			for $id (keys %Janus::nets) {
				$new = $Janus::nets{$id};
				next if $new->isa('Interface') || $id eq $net->id();
				push @out, $net->cmd2($net->cparam('linkname'), SERVER => "$id.janus", 2, $new->cparam('numeric'), $new->netname());
			}
		} else {
			push @out, $net->cmd2($net->cparam('linkname'), SERVER => "$id.janus", 2, $new->cparam('numeric'), $new->netname());
		}
		@out;
	}, NETSPLIT => sub {
		my($net,$act) = @_;
		my $gone = $act->{net};
		my $id = $gone->id();
		$net->cmd1(SQUIT => "$id.janus", "Reason? What's that?");
	}, CONNECT => sub {
		my($net,$act) = @_;
		my $nick = $act->{dst};
		return () if $act->{net}->id() ne $net->id();

		my $mode = join '', '+', map $txt2umode{$_}, $nick->umodes();
		my $vhost = $nick->info('vhost');
		$mode =~ s/[xth]//g; # TODO: list non-translated umodes
		$mode .= 'x';
		if ($vhost eq 'unknown.cloaked') {
			$vhost = '*'; # XXX: CA HACK
		} else {
			$mode .= 't';
		}
		unless ($net->param('show_roper') || $nick->info('_is_janus')) {
			$mode .= 'H' if $mode =~ /o/ && $mode !~ /H/;
		}
		my($hc, $srv) = (2,$nick->homenet()->id() . '.janus');
		($hc, $srv) = (1, $net->cparam('linkname')) if $srv eq 'janus.janus';
		my @out;
		push @out, $net->cmd1(NICK => $nick, $hc, $net->sjb64($nick->ts()), $nick->info('ident'), $nick->info('host'),
			$srv, 0, $mode, $vhost, ($nick->info('ip_64') || ()), $nick->info('name'));
		my $whois = $nick->info('swhois');
		push @out, $net->cmd1(SWHOIS => $nick, $whois) if defined $whois && $whois ne '';
		my $away = $nick->info('away');
		push @out, $net->cmd2($nick, AWAY => $away) if defined $away && $away ne '';
		if ($act->{reconnect}) {
			# XXX: this may not be the best way to generate these events
			for my $chan (@{$act->{reconnect_chans}}) {
				next unless $chan->is_on($net);
				my $mode = '';
				$chan->has_nmode($_, $nick) and $mode .= $net->txt2cmode($_) 
					for qw/n_voice n_halfop n_op n_admin n_owner/;
				$mode =~ tr/qaohv/*~@%+/;
				push @out, $net->cmd1(SJOIN => $net->sjb64($chan->ts()), $chan, $mode.$nick->str($net));
			}
		}
		@out;
	}, JOIN => sub {
		my($net,$act) = @_;
		if ($act->{src}->homenet()->id() eq $net->id()) {
			print "ERR: Trying to join nick to channel without rejoin" unless $act->{rejoin};
			return ();
		}
		my $chan = $act->{dst};
		my $mode = '';
		if ($act->{mode}) {
			$mode .= $net->txt2cmode($_) for keys %{$act->{mode}};
		}
		$mode =~ tr/qaohv/*~@%+/;
		$net->cmd1(SJOIN => $net->sjb64($chan->ts()), $chan->str($net), $mode.$net->_out($act->{src}));
	}, PART => sub {
		my($net,$act) = @_;
		$net->cmd2($act->{src}, PART => $act->{dst}, $act->{msg});
	}, KICK => sub {
		my($net,$act) = @_;
		$net->cmd2($act->{src}, KICK => $act->{dst}, $act->{kickee}, $act->{msg});
	}, MODE => sub {
		my($net,$act) = @_;
		my $src = $act->{src};
		if (ref $src && $src->isa('Nick') && $src->is_on($net)) {
			return $net->cmd2($src, MODE => $act->{dst}, $net->_mode_interp($act));
		} else {
			return $net->cmd2($src, MODE => $act->{dst}, $net->_mode_interp($act), 0); 
		}
	}, TOPIC => sub {
		my($net,$act) = @_;
		$net->cmd2($act->{src}, TOPIC => $act->{dst}, $act->{topicset}, 
			$net->sjb64($act->{topicts}), $act->{topic});
	}, MSG => sub {
		my($net,$act) = @_;
		return if $act->{dst}->isa('Network');
		my $type = $act->{msgtype} || 1;
		$type = 
			$type == 1 ? 'PRIVMSG' :
			$type == 2 ? 'NOTICE' :
			$type == 3 ? 'WHOIS' :
			sprintf '%03d', $type;
		$net->cmd2($act->{src}, $type, ($act->{prefix} || '').$net->_out($act->{dst}), $act->{msg});
	}, NICK => sub {
		my($net,$act) = @_;
		my $id = $net->id();
		$net->cmd2($act->{from}->{$id}, NICK => $act->{to}->{$id}, $act->{dst}->ts());
	}, NICKINFO => sub {
		my($net,$act) = @_;
		my $item = $act->{item};
		if ($item =~ /^(vhost|ident|name)$/) {
			$item =~ s/vhost/host/;
			if ($act->{dst}->homenet()->id() eq $net->id()) {
				my $src = $act->{src}->is_on($net) ? $act->{src} : $net->cparam('linkname');
				return $net->cmd2($src, 'CHG'.uc($item), $act->{dst}, $act->{value});
			} else {
				return $net->cmd2($act->{dst}, 'SET'.uc($item), $act->{value});
			}
		} elsif ($item eq 'away') {
			return $net->cmd2($act->{dst}, 'AWAY', defined $act->{value} ? $act->{value} : ());
		} elsif ($item eq 'swhois') {
			return $net->cmd1(SWHOIS => $act->{dst}, $act->{value});
		}
		();
	}, UMODE => sub {
		my($net,$act) = @_;
		local $_;
		my $pm = '';
		my $mode = '';
		for my $ltxt (@{$act->{mode}}) {
			my($d,$txt) = $ltxt =~ /([-+])(.+)/ or warn $ltxt;
			next if $txt eq 'vhost' || $txt eq 'vhost_x' || $txt eq 'helpop';
				# TODO unify umode mask list
				#never changed
			next if $txt eq 'hideoper' && !$net->param('show_roper');
			if ($pm ne $d) {
				$pm = $d;
				$mode .= $pm;
			}
			$mode .= $txt2umode{$txt};
		}
		unless ($net->param('show_roper')) {
			$mode .= '+H' if $mode =~ /\+[^-]*o/ && $mode !~ /\+[^-]*H/;
			$mode .= '-H' if $mode =~ /-[^+]*o/ && $mode !~ /-[^+]*H/;
		}
		$net->cmd2($act->{dst}, UMODE2 => $mode) if $mode;
	}, QUIT => sub {
		my($net,$act) = @_;
		return () unless $act->{dst}->is_on($net);
		$net->cmd2($act->{dst}, QUIT => $act->{msg});
	}, LINK => sub {
		my($net,$act) = @_;
		my $chan = $act->{dst}->str($net);
		$net->cmd1(GLOBOPS => "Channel $chan linked");
	}, LSYNC => sub {
		();
	}, LINKREQ => sub {
		my($net,$act) = @_;
		my $src = $act->{net};
		$net->cmd1(GLOBOPS => $src->netname()." would like to link $act->{slink} to $act->{dlink}");
	}, DELINK => sub {
		my($net,$act) = @_;
		if ($act->{net}->id() eq $net->id()) {
			my $name = $act->{split}->str($net);
			my $nick = $act->{src} ? $act->{src}->str($net) : 'janus';
			$net->cmd1(GLOBOPS => "Channel $name delinked by $nick");
		} else {
			my $name = $act->{dst}->str($net);
			$net->cmd1(GLOBOPS => "Network ".$act->{net}->netname()." dropped channel $name");
		}			
	}, KILL => sub {
		my($net,$act) = @_;
		my $killfrom = $act->{net};
		return () unless $net->id() eq $killfrom->id();
		return () unless defined $act->{dst}->str($net);
		$net->cmd2($act->{src}, KILL => $act->{dst}, $act->{msg});
	},
);

} 1;
