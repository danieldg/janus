package Unreal;
use base 'Network';
use strict;
use warnings;
use Nick;
use Interface;

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

my %unreal_net = (
	txt2cmode => \%txt2cmode,
	txt2umode => \%txt2umode,
	cmode2txt => \%cmode2txt,
	umode2txt => \%umode2txt,
	nicklen => 30,
);

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
	$net->{params} = \%unreal_net;
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
	
	my $src = $net->nick($_[0]);
	my $dst = $type eq 'set' ? $src : $net->nick($_[2]);
	my %a = (
		type => 'NICKINFO',
		src => $src,
		dst => $dst,
		item => lc $act,
		value => $_[-1],
	);
	if ($act eq 'vhost' && !($dst->{mode}->{vhost} || $dst->{mode}->{vhost_x})) {
		return (\%a, +{
			type => 'UMODE',
			dst => $dst,
			mode => ['+vhost', '+vhost_x'],
		});
	} else {
		return \%a;
	}
}

sub ignore {
	return ();
}

sub pm_notice {
	my $net = shift;
	my $notice = $_[1] eq 'NOTICE' || $_[1] eq 'B';
	return () if $_[2] eq 'AUTH' && $_[0] =~ /\./;
	my $src = $net->nick($_[0]) or return ();
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
		return () unless $dst;
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
		my $nick = Nick->new(
			homenet => $net,
			homenick => $_[2],
		#	hopcount => $_[3],
			nickts => $net->sjbint($_[4]),
			ident => $_[5],
			host => $_[6],
			vhost => $_[6],
			home_server => $net->srvname($_[7]),
			servicests => $net->sjbint($_[8]),
			name => $_[-1],
		);
		if (@_ >= 12) {
			my @m = split //, $_[9];
			warn unless '+' eq shift @m;
			$nick->{mode} = +{ map { $umode2txt{$_} => 1 } @m };
			delete $nick->{mode}->{''};
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
		
		unless ($nick->{mode}->{vhost}) {
			$nick->{vhost} = $nick->{mode}->{vhost_x} ? $nick->{chost} : $nick->{host};
		}

		my @out;
		if (exists $net->{nicks}->{lc $_[2]}) {
			# nick collision
			my $cnick = $net->{nicks}->{lc $_[2]};
			if ($cnick->{nickts} >= $nick->{nickts}) {
				# the existing nick did not win; re-tag it
				push @out, +{
					type => 'CONNECT',
					dst => $cnick,
					net => $net,
					reconnect => 1,
					nojlink => 1,
				};
			}
			if ($cnick->{nickts} <= $nick->{nickts}) {
				# the new nick did not win; kill it
				$net->send($net->cmd1(KILL => $_[2], "Nick Collision"));
				delete $net->{nicks}->{lc $_[2]};
			} else {
				$net->{nicks}->{lc $_[2]} = $nick;
			}
		} else {
			$net->{nicks}->{lc $_[2]} = $nick;
		}
		@out; #not transmitted to remote nets or acted upon until joins
	}, QUIT => sub {
		my $net = shift;
		my $nick = $net->nick($_[0]) or return ();
		return {
			type => 'QUIT',
			dst => $nick,
			msg => $_[2],
		};
	}, KILL => sub {
		my $net = shift;
		my $src = $net->item($_[0]);
		my $dst = $net->nick($_[2]) or return ();

		if ($dst->{homenet}->id() eq $net->id()) {
			return {
				type => 'QUIT',
				dst => $dst,
				msg => "Killed ($_[3])",
				killer => $src,
			};
		}
		return {
			type => 'KILL',
			src => $src,
			dst => $dst,
			net => $net,
			msg => $_[3],
		};
	}, SVSKILL => sub {
		my $net = shift;
		my $nick = $net->nick($_[2]) or return ();
		return () if $nick->{homenet}->id() eq $net->id(); 
			# if local, wait for the QUIT that will be sent along in a second
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
		my @mode;
		my $pm = '+';
		my $vh_pre = $nick->{mode}->{vhost} ? 3 : $nick->{mode}->{vhost_x} ? 1 : 0;
		my $vh_post = $vh_pre;
		for (split //, $_[2]) {
			if (/[-+]/) {
				$pm = $_;
			} else {
				my $txt = $umode2txt{$_};
				if ($txt eq 'vhost') {
					warn '+t should not be in a umode' if $pm eq '+';
					$vh_post = $vh_post & 1;
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
			my $vhost = $vh_post ? $nick->{chost} : $nick->{host};
			push @out,{
				type => 'NICKINFO',
				dst => $nick,
				item => 'host',
				value => $vhost,
			};
		}				
		@out;
	},
	SETIDENT => \&nickact,
	CHGIDENT => \&nickact,
	SETHOST => \&nickact,
	CHGHOST => \&nickact,
	SETNAME => \&nickact,
	CHGNAME => \&nickact,
	SWHOIS => \&ignore,

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
				my %mh = map { tr/*~@%+/qaohv/; $cmode2txt{$_} => 1 } split //, $nmode;
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
	EOS => sub {
		my $net = shift;
		my $srv = $_[0];
		if ($net->{server}->{lc $srv}->{parent} eq lc $net->{linkname}) {
			return +{
				type => 'LINKED',
				net => $net,
				sendto => [],
			};
		}
		();
	},

# Messages
	PRIVMSG => \&pm_notice,
	NOTICE => \&pm_notice,
	SMO => \&ignore,
	SENDSNO => \&ignore,
	GLOBOPS => \&ignore,
	WALLOPS => \&ignore,
	CHATOPS => \&ignore,
	NACHAT => \&ignore,
	ADMINCHAT => \&ignore,
	
	TKL => sub {
		my $net = shift;
		my $iexpr;
		if ($_[3] eq 'G') {
			$iexpr = '*!'.$_[4].'@'.$_[5].'%*';
		} elsif ($_[3] eq 'Q') {
			$iexpr = $_[5].'!*';
		}
		return unless $iexpr;
		my $expr = &Interface::banify($iexpr);
		if ($_[2] eq '+') {
			my %ban = (
				expr => $expr,
				ircexpr => $iexpr,
				setter => $_[6],
				expire => $_[7],
				# 8 = set time
				reason => $_[9],
			);
			$net->{ban}->{$expr} = \%ban;
		} else {
			delete $net->{ban}->{$expr};
		}
		();
	},
);

sub _out {
	my($net,$itm) = @_;
	return $itm unless ref $itm;
	$itm->str($net);
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
	CONNECT => sub {
		my($net,$act) = @_;
		my $nick = $act->{dst};
		return if $act->{net}->id() ne $net->id();
		my $mode = join '', '+', sort map $txt2umode{$_}, keys %{$nick->{mode}};
		$mode =~ s/[xt]//g;
		$mode .= 'xt';
		# TODO set hopcount to 2 and use $nick->{homenet}->id().'.janus' or similar as server name
		$net->cmd1(NICK => $nick, 1, $net->sjb64($nick->{nickts}), $nick->{ident}, $nick->{host},
			$net->{linkname}, 0, $mode, $nick->{vhost}, ($nick->{ip_64} || '*'), $nick->{name});
	}, JOIN => sub {
		my($net,$act) = @_;
		my $chan = $act->{dst};
		my $mode = '';
		if ($act->{mode}) {
			$mode .= $txt2cmode{$_} for keys %{$act->{mode}};
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
		$net->cmd2($act->{src}, TOPIC => $act->{dst}, $act->{topicset}, 
			$net->sjb64($act->{topicts}), $act->{topic});
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
		if ($act->{dst}->{homenet}->id() eq $net->id()) {
			my $src = $act->{src}->is_on($net) ? $act->{src} : $net->{linkname};
			$net->cmd2($src, 'CHG'.uc($item), $act->{dst}, $act->{value});
		} else {
			$net->cmd2($act->{dst}, 'SET'.uc($item), $act->{value});
		}
	}, UMODE => sub {
		my($net,$act) = @_;
		local $_;
		my $pm = '';
		my $mode = '';
		for my $ltxt (@{$act->{mode}}) {
			my($d,$txt) = $ltxt =~ /([-+])(.+)/ or warn $ltxt;
			next if $txt eq 'vhost' || $txt eq 'vhost_x'; #never changed
			if ($pm ne $d) {
				$pm = $d;
				$mode .= $pm;
			}
			$mode .= $txt2umode{$txt};
		}
		$net->cmd2($act->{dst}, UMODE2 => $mode) if $mode;
	}, QUIT => sub {
		my($net,$act) = @_;
		$net->cmd2($act->{dst}, QUIT => $act->{msg});
	}, LINK => sub {
		my($net,$act) = @_;
		my $chan = $act->{dst}->str($net);
		$net->cmd1(GLOBOPS => "Channel $chan linked");
	}, LSYNC => sub {
		();
	}, LINKREQ => sub {
		();
	}, DELINK => sub {
		my($net,$act) = @_;
		if ($act->{net}->id() eq $net->id()) {
			my $name = $act->{split}->str($net);
			my $nick = $act->{src} ? $act->{src}->str($net) : 'janus';
			$net->cmd1(GLOBOPS => "Channel $name delinked by $nick");
		} else {
			my $name = $act->{dst}->str($net);
			$net->cmd1(GLOBOPS => "Network $act->{net}->{netname} dropped channel $name");
		}			
	}, NETLINK => sub {
		my($net,$act) = @_;
		my $new = $act->{net};
		my $id = $new->id();
		$net->cmd1(GLOBOPS => "Janus Network $id ($new->{netname}) is now linked");
	}, NETSPLIT => sub {
		();
	}, KILL => sub {
		my($net,$act) = @_;
		my $killfrom = $act->{net};
		return () unless $net->id() eq $killfrom->id();
		return () unless defined $act->{dst}->str($net);
		$net->cmd2($act->{src}, KILL => $act->{dst}, $act->{msg});
	},
);

1;
