package Unreal;
use base 'Network';
use strict;
use warnings;
use Nick;

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

sub debug {
	print @_, "\n";
}

sub str {
	$_[1]->{linkname};
}

sub intro {
	unless (ref $_[0]) {
		my $class = shift;
		bless $_[0], $class;
	}
	my $net = shift;
	if ($_[0]) {
		# temporary until SERVER message handling properly set up
		WAIT: while (sysread $net, $net->{recvq}, 8192, length $net->{recvq}) {
			while ($net->{recvq} =~ /[\r\n]/) {
				(my $line, $net->{recvq}) = split /[\r\n]+/, $net->{recvq}, 2;
				$net->parse($line);
				last WAIT if $line =~ /SERVER/;
			}
		}
	}
	$net->send(
		"PASS :$net->{linkpass}",
		'PROTOCTL NOQUIT TOKEN NICKv2 CLK NICKIP SJOIN SJOIN2 SJ3 VL NS UMODE2 TKLEXT SJB64',
		"SERVER $net->{linkname} 1 :U2309-hX6eE-$net->{numeric} Janus Network Link",
	);
	$net->{txt2cmode} = \%txt2cmode;
	$net->{txt2umode} = \%txt2umode;
	$net->{cmode2txt} = \%cmode2txt;
	$net->{umode2txt} = \%umode2txt;
}

# parse one line of input
sub parse {
	my ($net, $line) = @_;
	debug "IN\@$net->{id} $line";
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
	unless (exists $fromirc{$cmd}) {
		debug "Unknown command $cmd";
		return ();
	}
	$fromirc{$cmd}->($net,@args);
}

sub send {
	my $net = shift;
	# idea: because SSL nonblocking has some problems, and nonblocking send in
	# general requires maintinance of a sendq, have a separate thread handle send with a
	# Thread::Queue here
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
	debug "OUT\@$net->{id} $_" for @out;
	$net->{sock}->print(map "$_\r\n", @out);
}

sub vhost {
	my $nick = $_[1];
	return $nick->{vhost} if $nick->{mode}->{vhost};
	return $nick->{chost} if $nick->{mode}->{vhost_x};
	$nick->{host};
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
	my($type, $act) = ($_[2] =~ /(SET|CHG)(HOST|IDENT|NAME)/i);
	$act =~ s/host/vhost/i;

	my %a = (
		type => 'NICKINFO',
		src => $net->nick($_[0]),
		item => lc $act,
		value => $_[-1],
	);
	$a{dst} = $type eq 'SET' ? $a{src} : $net->nick($_[2]);
	\%a;
}

sub ignore {
	return ();
}

sub pm_notice {
	my $net = shift;
	my $notice = $_[1] eq 'NOTICE' || $_[1] eq 'B';
	my $src = $net->nick($_[0]);
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
			notice => $notice,
		};
	} elsif ($_[2] =~ /^(\S+?)(@\S+)?$/) {
		# nick message, possibly with a server mask
		# server mask is ignored as the server is going to be wrong anyway
		my $dst = $net->nick($1);
		return () if !$dst && $_[2] eq 'AUTH';
		return {
			type => 'MSG',
			src => $src,
			dst => $dst,
			msg => $_[3],
			notice => $notice,
		};
	}
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
	return $net->{srvname}->{$num} if exists $net->{srvname}->{$num};
	return $num;
}

%fromirc = (
# User Operations
	NICK => sub {
		my $net = shift;
		if (@_ < 10) {
			# Nick Change
			my $nick = $net->nick($_[0]);
			my %a = (
				type => 'NICK',
				src => $nick,
				dst => $nick,
				nick => $_[2],
			);
			$a{nickts} = $net->sjbint($_[3]) if @_ == 4;
			return \%a;
		}
		# NICKv2 introduction
		my $nick = Nick->new(
			homenet => $net,
			homenick => $_[2],
		#	hopcount => $_[3],
			nickts => $net->sjbint($_[4]),
			ident => $_[5],
			host => $_[6],
			home_server => $net->srvname($_[7]),
			servicests => $net->sjbint($_[8]),
			name => $_[-1],
		);
		if (@_ >= 12) {
			$nick->umode($_[9]);
			$nick->{vhost} = $_[10];
		}
		if (@_ >= 14) {
			$nick->{chost} = $_[11];
			$nick->{ip_64} = $_[12];
			local $_ = $_[12];
			s/=+//;
			my $textip_table = join '', 'A'..'Z','a'..'z', 0 .. 9, '+/';
			if (length == 6) {
				my $binaddr = 0;
				for (split //, $_[12]) {
					$binaddr = $binaddr*64 + index $textip_table, $_;
				}
				$binaddr /= 16;
				$nick->{ip} = join '.', unpack 'C4', pack 'N', $binaddr;
			} elsif (length == 22) {
				s/(.)/sprintf '%06b', index $textip_table, $1/eg;
				s/(.{16})/sprintf '%x:', oct "0b$1"/eg;
				s/:[^:]*$//;
				$nick->{ip} = $_;
			}
		}
		$net->{nicks}->{lc $_[2]} = $nick;
		return (); #not transmitted to remote nets or acted upon until joins
	}, QUIT => sub {
		my $net = shift;
		my $nick = $net->nick($_[0]);
		return {
			type => 'QUIT',
			src => $nick,
			dst => $nick,
			msg => $_[2],
		};
	}, KILL => sub {
		my $net = shift;
		my $src = $net->nick($_[0]);
		my $dst = $net->nick($_[2]);

		return () unless $dst; # killing an already dead nick
		if ($dst->{homenet}->id() eq $net->id()) {
			return {
				type => 'QUIT',
				src => $src,
				dst => $dst,
				msg => "Killed ($_[3])",
			};
		}
		return {
			type => 'KILL',
			src => $src,
			dst => $dst,
			msg => $_[3],
		};
	}, UMODE2 => sub {
		my $net = shift;
		my $nick = $net->nick($_[0]);
		return {
			type => 'UMODE',
			src => $nick,
			dst => $nick,
			value => $_[2],
		}
	},
	SETIDENT => \&nickact,
	CHGIDENT => \&nickact,
	SETHOST => \&nickact,
	CHGHOST => \&nickact,
	SETNAME => \&nickact,
	CHGNAME => \&nickact,
	SWHOIS => \&ignore,
	SVSKILL => \&ignore, # the client sends a quit message when this is recieved

# Channel Actions
	JOIN => sub {
		my $net = shift;
		my $nick = $net->nick($_[0]);
		my @act;
		for (split /,/, $_[2]) {
			my $chan = $net->chan($_, 1);
			push @act, $chan->try_join($nick);
		}
		@act;
	}, SJOIN => sub {
		my $net = shift;
		my $chan = $net->chan($_[3], 1);
		$chan->timesync($net->sjbint($_[2])); # TODO actually sync
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
				my $nick = $net->nick($2);
				my %mh = map { tr/*~@%+/qaohv/; $cmode2txt{$_} => 1 } split //, $nmode;
				push @acts, $chan->try_join($nick, \%mh);
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
		return {
			type => 'PART',
			src => $net->nick($_[0]),
			dst => $net->chan($_[2]),
			msg => @_ ==4 ? $_[3] : '',
		};
	}, KICK => sub {
		my $net = shift;
		return {
			type => 'KICK',
			src => $net->item($_[0]),
			dst => $net->chan($_[2]),
			kickee => $net->nick($_[3]),
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
# Server actions
	SERVER => sub {
		my $net = shift;
		# :src SERVER name hopcount [numeric] description
		my $name = lc $_[2];
		my $desc = $_[-1];

		my $snum = $net->sjb64((@_ > 5          ? $_[4] : 
				($desc =~ s/^U\d+-\S+-(\d+) //) ? $1    : 0), 1);

		$net->{server}->{$name} = {
			parent => lc ($_[0] || $net->{linkname}),
			hops => $_[3],
			numeric => $snum,
		};
		$net->{srvname}->{$snum} = $name if $snum;

		();
	}, SQUIT => sub {
		my $net = shift;
		my $netid = $net->id();
		my $srv = $net->srvname($_[2]);
		my $splitfrom = $net->{server}->{$srv}->{parent};
		
		my %sgone = (lc $srv => 1);
		my $k = 0;
		while ($k != scalar keys %sgone) {
			# loop to traverse each layer of the map
			$k = scalar keys %sgone;
			for (keys %{$net->{server}}) {
				$sgone{$_} = 1 if $sgone{$net->{server}->{$_}->{parent}};
			}
		}
		delete $net->{srvname}->{$net->{server}{$_}{numeric}} for keys %sgone;
		delete $net->{server}->{$_} for keys %sgone;

		my @quits;
		for my $n (keys %{$net->{nicks}}) {
			my $nick = $net->{nicks}->{$n};
			next unless $nick->{homenet}->id() eq $netid;
			next unless $sgone{lc $nick->{home_server}};
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
		my $from = $_[3] || $net->{linkname};
		$net->send($net->cmd1('PONG', $from, $_[2]));
		();
	},
	PONG => \&ignore,
	PASS => \&ignore,
	PROTOCTL => \&ignore,
	NETINFO => \&ignore,
	EOS => \&ignore,

# Messages
	PRIVMSG => \&pm_notice,
	NOTICE => \&pm_notice,
	SMO => \&ignore,
	SENDSNO => \&ignore,
	GLOBOPS => \&ignore,
	WALLOPS => \&ignore,
);

sub _out {
	my($net,$itm) = @_;
	return $itm unless ref $itm;
	$itm->str($net);
}

sub cmd1 {
	my($net,$cmd) = (shift,shift);
	my $out = $cmd2token{$cmd};
	if (@_) {
		my $end = $net->_out(pop @_);
		$out .= ' '.$net->_out($_) for @_;
		$out .= ' :'.$end;
	}
	$out;
}

sub cmd2 {
	my($net,$src,$cmd) = (shift,shift,shift);
	my $out = ':'.$net->_out($src).' '.$cmd2token{$cmd};
	if (@_) {
		my $end = $net->_out(pop @_);
		$out .= ' '.$net->_out($_) for @_;
		$out .= ' :'.$end;
	}
	$out;
}

%toirc = (
	CONNECT => sub {
		my($net,$act) = @_;
		my $nick = $act->{src};
		my $mode = join '', '+', map $txt2umode{$_}, keys %{$nick->{mode}};
		my $vhost = $nick->vhost();
		$mode =~ s/[xt]//g;
		$mode .= 'xt';
		# TODO set hopcount to 2 and use $nick->{homenet}->id().'.janus' or similar as server name
		$net->cmd1(NICK => $nick, 1, $net->sjb64($nick->{nickts}), $nick->{ident}, $nick->{host},
			$net->{linkname}, 0, $mode, $vhost, ($nick->{ip_64} || '*'), $nick->{name});
	}, JOIN => sub {
		my($net,$act) = @_;
		my $chan = $act->{dst};
		my $mode = '';
		if ($act->{mode}) {
			$mode .= $cmode2txt{$_} for keys %{$act->{mode}};
		}
		$mode =~ tr/qaohv/*~@%+/;
		$net->cmd1(SJOIN => $net->sjb64($chan->{ts}), $chan->str($net), $mode.$act->{src}->str($net));
	}, PART => sub {
		my($net,$act) = @_;
		$net->cmd2($act->{src}, PART => $act->{dst}, $act->{msg});
	}, KICK => sub {
		my($net,$act) = @_;
		$net->cmd2($act->{src}, KICK => $act->{dst}, $act->{kickee}, $act->{msg});
	}, MODE => sub {
		my($net,$act) = @_;
		$net->cmd2($act->{src}, MODE => $act->{dst}, $net->_mode_interp($act));
	}, TOPIC => sub {
		my($net,$act) = @_;
		my @t = (TOPIC => $act->{dst}, $act->{topicset}, $net->sjb64($act->{topicts}), $act->{topic});
		if ($act->{src}) {
			$net->cmd2($act->{src},@t);
		} else {
			$net->cmd1(@t);
		}
	}, MSG => sub {
		my($net,$act) = @_;
		$net->cmd2($act->{src}, ($act->{notice} ? 'NOTICE' : 'PRIVMSG'), 
			$act->{dst}, $act->{msg});
	}, NICK => sub {
		my($net,$act) = @_;
		my $id = $net->id();
		$net->cmd2($act->{from}->{$id}, NICK => $act->{to}->{$id}, $act->{dst}->{nickts});
	}, NICKINFO => sub {
		my($net,$act) = @_;
		my $item = $act->{item};
		$item =~ s/vhost/host/;
		$net->cmd2($act->{dst}, 'SET'.uc($item), $act->{value});
	}, UMODE => sub {
		my($net,$act) = @_;
		$net->cmd2($act->{dst}, UMODE2 => $act->{value});
	}, QUIT => sub {
		my($net,$act) = @_;
		$net->cmd2($act->{dst}, QUIT => $act->{msg});
	},
);

1;
