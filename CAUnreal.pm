# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package CAUnreal;
BEGIN {
	&Janus::load('LocalNetwork');
	&Janus::load('Nick');
}
use Persist 'LocalNetwork';
use strict;
use warnings;

our($VERSION) = '$Rev$' =~ /(\d+)/;

my @sendq   :Persist(sendq);
my @srvname :Persist(srvname);
my @servers :Persist(servers);
my @auth    :Persist(auth);
 
sub _init {
	my $net = shift;
	$sendq[$$net] = [];
}

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
	p no_privmsg
	P hide_chans
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
	f v_flood
	i r_invite
	k v_key
	l s_limit
	m r_moderated
	n r_mustjoin
	p r_private
	r r_register
	s r_secret
	t r_topic
	u r_auditorium
	z r_sslonly
	A r_operadmin
	C r_ctcpblock
	G r_badword
	K r_noknock
	L v_forward
	M r_regmoderated
	N r_norenick
	O r_oper
	Q r_nokick
	R r_reginvite
	S r_colorstrip
	T r_opernetadm
	V r_noinvite
	X r_nooperover
	Y r_opersvsadm
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

my $textip_table = join '', 'A'..'Z','a'..'z', 0 .. 9, '+/';

sub nicklen { 30 }

sub debug {
	print @_, "\e[0m\n";
}

sub str {
	my $net = shift;
	$net->id().'.janus';
}

sub intro {
	my($net,$param) = @_;
	$net->SUPER::intro($param);
	$net->send(
		'PASS :'.$param->{sendpass},
		'PROTOCTL NOQUIT TOKEN NICKv2 CLK NICKIP SJOIN SJOIN2 SJ3 VL NS UMODE2 TKLEXT SJB64',
		"SERVER $param->{linkname} 1 :U2309-hX6eE-$param->{numeric} Janus Network Link",
	);
}

# parse one line of input
sub parse {
	my ($net, $line) = @_;
	debug "\e[0;32m     IN@".$net->id().' '. $line;
	$net->pong();
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
	unless ($auth[$$net] || $cmd eq 'PASS' || $cmd eq 'SERVER' || $cmd eq 'PROTOCTL' || $cmd eq 'ERROR') {
		return () if $cmd eq 'NOTICE'; # NOTICE AUTH ... annoying
		$net->send('ERROR :Not authorized');
		return +{
			type => 'NETSPLIT',
			net => $net,
			msg => 'Sent command '.$cmd.' without authenticating',
		};
	}
	return $net->nick_msg(@args) if $cmd =~ /^\d+$/;
	unless (exists $fromirc{$cmd}) {
		debug "Unknown command '$cmd'";
		return ();
	}
	$fromirc{$cmd}->($net,@args);
}

sub send {
	my $net = shift;
	for my $act (@_) {
		if (ref $act) {
			my $type = $act->{type};
			if (exists $toirc{$type}) {
				push @{$sendq[$$net]}, $toirc{$type}->($net, $act);
			} else {
				debug "Unknown action type '$type'";
			}
		} else {
			push @{$sendq[$$net]}, $act;
		}
	}
}

sub dump_sendq {
	my $net = shift;
	local $_;
	my $q = '';
	my %sjmerge;
	my $mode = 0;
	for my $i (@{$sendq[$$net]}, '') {
		$_ = ref $i ? $i->[0] : '';
		my $cmode = /JOIN|FLOAT_ADD/ ? 1 : 0;
		$cmode = $mode if /FLOAT_ALL/;
		if ($mode == 1 && $cmode != 1) {
			local $_;
			for my $c (keys %sjmerge) {
				$_ = $sjmerge{$c}{j}; chomp;
				# IRC limits to 512 char lines; we output a line like: ~ !123456 #<32> :<510-45>
				$q .= $net->cmd1(SJOIN => $sjmerge{$c}{ts}, $c, $1)."\r\n" while s/^(.{400,465}) //;
				$q .= $net->cmd1(SJOIN => $sjmerge{$c}{ts}, $c, $_)."\r\n";
			}
			%sjmerge = ();
		}
		$mode = $cmode;
		if (/JOIN/) {
			my $c = $i->[2];
			if ($sjmerge{$c}{ts} && $sjmerge{$c}{ts} ne $i->[1]) {
				if ($net->sjbint($sjmerge{$c}{ts}) > $net->sjbint($i->[1])) {
					$sjmerge{$c}{j} =~ s/(^|\s)[\*\@\$\%\+]+/$1/g;
					$sjmerge{$c}{ts} = $i->[1];
				} else {
					$i->[3] =~ s/(^|\s)[\*\@\$\%\+]+/$1/g;
				}
			} else {
				$sjmerge{$c}{ts} = $i->[1];
			}
			$sjmerge{$c}{j} .= $i->[3].' ';
		} elsif (/^FLOAT_/) {
			$q .= join "\r\n", @$i[1 .. $#$i], '';
		} elsif ($_ eq '') {
			$q .= $i."\r\n" if $i;
		} else {
			warn "ignoring unknown OUTDATA $_";
		}
	}
	$sendq[$$net] = [];
	debug "\e[0;34m    OUT@".$net->id().' '.$_ for split /[\r\n]+/, $q;
	$q;
}

my %skip_umode = (
	# TODO make this configurable
	vhost => 1,
	vhost_x => 1,
	helpop => 1,
	registered => 1,
);

sub umode_text {
	my($net,$nick) = @_;
	my $mode = '+';
	for my $m ($nick->umodes()) {
		next if $skip_umode{$m};
		next unless exists $txt2umode{$m};
		$mode .= $txt2umode{$m};
	}
	unless ($net->param('show_roper') || $nick->info('_is_janus')) {
		$mode .= 'H' if $mode =~ /o/ && $mode !~ /H/;
	}
	$mode . 'xt';
}

sub _connect_ifo {
	my ($net, $nick) = @_;

	my $mode = $net->umode_text($nick);
	my $vhost = $nick->info('vhost');
	if ($vhost eq 'unknown.cloaked') {
		$vhost = '*'; # XXX: CA HACK
		$mode =~ s/t//;
	}
	my($hc, $srv) = (2,$nick->homenet()->id() . '.janus');
	($hc, $srv) = (1, $net->cparam('linkname')) if $srv eq 'janus.janus';

	my $ip = $nick->info('ip') || '*';
	if ($ip =~ /^[0-9.]+$/) {
		$ip =~ s/(\d+)\.?/sprintf '%08b', $1/eg; #convert to binary
		$ip .= '0000=='; # base64 uses up 36 bits, so add 4 from the 32...
		$ip =~ s/([01]{6})/substr $textip_table, oct("0b$1"), 1/eg;
	} elsif ($ip =~ /^[0-9a-f:]+$/) {
		$ip .= ':';
		$ip =~ s/::/:::/ while $ip =~ /::/ && $ip !~ /(.*:){8}/;
		# fully expanded IPv6 address, with an additional : at the end
		$ip =~ s/([0-9a-f]*):/sprintf '%016b', hex $1/eg;
		$ip .= '0000==';
		$ip =~ s/([01]{6})/substr $textip_table, oct("0b$1"), 1/eg;
	} else {
		warn "Unrecognized IP address '$ip'" unless $ip eq '*';
		$ip = '*';
	}
	unless ($ip eq '*' || length $ip == 8 || length $ip == 24) {
		warn "Dropping NICKIP to avoid crashing unreal!";
		$ip = $nick->info('ip');
		print "$ip\n";
		if ($ip =~ /^[0-9.]+$/) {
			$ip =~ s/(\d+)\.?/sprintf '%08b', $1/eg; #convert to binary
			print "$ip\n";
			$ip .= '0000=='; # base64 uses up 36 bits, so add 4 from the 32...
			$ip =~ s/([01]{6})/substr $textip_table, oct("0b$1"), 1/eg;
			print "$ip\n";
		} elsif ($ip =~ /^[0-9a-f:]+$/) {
			$ip .= ':';
			$ip =~ s/::/:::/ while $ip =~ /::/ && $ip !~ /(.*:){8}/;
			print "$ip\n";
			# fully expanded IPv6 address, with an additional : at the end
			$ip =~ s/([0-9a-f]*):/sprintf '%016b', hex $1/eg;
			$ip .= '0000==';
			print "$ip\n";
			$ip =~ s/([01]{6})/substr $textip_table, oct("0b$1"), 1/eg;
			print "$ip\n";
		}
		$ip = '*';
	}
	my @out;
	push @out, $net->cmd1(NICK => $nick, $hc, $net->sjb64($nick->ts()), $nick->info('ident'), $nick->info('host'),
		$srv, 0, $mode, $vhost, $nick->info('name'));
	my $whois = $nick->info('swhois');
	push @out, $net->cmd1(SWHOIS => $nick, $whois) if defined $whois && $whois ne '';
	my $away = $nick->info('away');
	push @out, $net->cmd2($nick, AWAY => $away) if defined $away && $away ne '';
	[ 'FLOAT_ADD', @out ];
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
		$src = $dst = $net->mynick($_[0]);
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
	my $src = $net->item($_[0]);
	my $msg = [ @_[3..$#_] ];
	my $dst = $net->nick($_[2]) or return ();
	return {
		type => 'MSG',
		src => $src,
		dst => $dst,
		msg => $msg,
		msgtype => $_[1],
	};
}

sub nc_msg {
	my $net = shift;
	return () if $_[2] eq 'AUTH' && $_[0] =~ /\./;
	my $src = $net->item($_[0]) or return ();
	my $msgtype = $_[1];
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
	();
}

my %opermodes = (
	oper => 1,
	coadmin => 2,
	admin => 4,
	service => 8,
	svs_admin => 16,
	netadmin => 32,
);

my @opertypes = (
	'IRC Operator', 'Server Co-Admin', 'Server Administrator', 
	'Service', 'Services Administrator', 'Network Administrator',
);

sub operlevel {
	my($net, $nick) = @_;
	my $lvl = 0;
	for my $m (keys %opermodes) {
		next unless $nick->has_mode($m);
		$lvl |= $opermodes{$m};
	}
	$lvl;
}

sub _parse_umode {
	my($net, $nick, $mode) = @_;
	my @mode;
	my $pm = '+';
	my $vh_pre = $nick->has_mode('vhost') ? 3 : $nick->has_mode('vhost_x') ? 1 : 0;
	my $vh_post = $vh_pre;
	my $oper_pre = $net->operlevel($nick);
	my $oper_post = $oper_pre;
	for (split //, $mode) {
		if (/[-+]/) {
			$pm = $_;
		} elsif (/d/ && $_[3]) {
			# adjusts the services TS - which is restricted to the local network
		} else {
			my $txt = $umode2txt{$_} or do {
				warn "Unknown umode '$_'";
				next;
			};
			if ($txt eq 'vhost') {
				$vh_post = $pm eq '+' ? 3 : $vh_post & 1;
			} elsif ($txt eq 'vhost_x') {
				$vh_post = $pm eq '+' ? $vh_post | 1 : 0;
			} elsif ($opermodes{$txt}) {
				$oper_post = $pm eq '+' ? $oper_post | $opermodes{$txt} : $oper_post & ~$opermodes{$txt};
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
		if ($vh_post > 1) {
			#invalid
			warn "Ignoring extraneous umode +t";
		} else {
			my $vhost = $vh_post ? $nick->info('chost') : $nick->info('host');
			push @out,{
				type => 'NICKINFO',
				dst => $nick,
				item => 'vhost',
				value => $vhost,
			};
		}
	}

	if ($oper_pre != $oper_post) {
		my $t = undef;
		$oper_post & (1 << $_) ? $t = $opertypes[$_] : 0 for 0..$#opertypes;
		push @out, +{
			type => 'NICKINFO',
			dst => $nick,
			item => 'opertype',
			value => $t,
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
			my $nick = $net->mynick($_[0]) or return ();
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
			$nick{mode} = +{ map { 
				if (exists $umode2txt{$_}) {
					$umode2txt{$_} => 1 
				} else {
					warn "Unknown umode '$_'";
					();
				}
			} @m };
			$nick{info}{vhost} = $_[10];
		}
		if (@_ >= 13) {
			local $_;
			if (@_ >= 14) {
				$nick{info}{chost} = $_[11];
				$_ = $_[12];
			} else {
				$nick{info}{chost} = 'unknown.cloaked';
				$_ = $_[11];
			}				
			if (s/=+//) {
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
		my $oplvl = 0;
		for my $m (keys %opermodes) {
			$oplvl |= $opermodes{$m} if $nick{mode}{$m};
		}
		$oplvl & (1 << $_) ? $nick{info}{opertype} = $opertypes[$_] : 0 for 0..$#opertypes;

		my $nick = Nick->new(%nick);
		my($good, @out) = $net->nick_collide($_[2], $nick);
		if ($good) {
			push @out, +{
				type => 'NEWNICK',
				dst => $nick,
			};
		} else {
			$net->send($net->cmd1(KILL => $_[2], 'hub.janus (Nick collision)'));
		}
		@out;
	}, QUIT => sub {
		my $net = shift;
		my $nick = $net->mynick($_[0]) or return ();
		# normal boring quit
		return +{
			type => 'QUIT',
			dst => $nick,
			msg => $_[2],
		};
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
		if ($nick->homenet()->id() eq $net->id()) {
			return {
				type => 'QUIT',
				dst => $nick,
				msg => $_[3],
				killer => $net,
			};
		} elsif (lc $nick->homenick() eq lc $_[2]) {
			# This is an untagged nick. We assume that the reason this
			# nick was killed was something like a GHOST command and set up
			# a reconnection with tag
			$net->release_nick(lc $_[2]);
			return +{
				type => 'RECONNECT',
				dst => $nick,
				net => $net,
				killed => 1,
				nojlink => 1,
			};
		} else {
			# This was a tagged nick. If we reintroduce this nick, there is a
			# danger of running into a fight with services - for example,
			# OperServ session limit kills will continue. So we interpret this
			# just as a normal kill.
			return +{
				type => 'KILL',
				src => $net->item($_[0]),
				dst => $nick,
				net => $net,
				msg => $_[3],
			};
		}
	}, SVSNICK => sub {
		my $net = shift;
		my $nick = $net->nick($_[2]) or return ();
		if ($nick->homenet->id() eq $net->id()) {
			warn "Misdirected SVSNICK!";
			return ();
		} elsif (lc $nick->homenick eq lc $_[2]) {
			$net->release_nick(lc $_[2]);
			return +{
				type => 'RECONNECT',
				src => $net->item($_[0]),
				dst => $nick,
				net => $net,
				killed => 0,
				sendto => [ $net ],
			};
		} else {
			print "Ignoring SVSNICK on already tagged nick\n";
			return ();
		}	
	}, UMODE2 => sub {
		my $net = shift;
		my $nick = $net->mynick($_[0]) or return ();
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
			$mode =~ s/[raAN]//g; # List of umode changes NOT rejected by janus
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
		if ($nick->homenet->id() ne $net->id()) {
			$net->send($net->cmd1(SWHOIS => $nick, ($nick->info('swhois') || '')));
			return ();
		}
		return +{
			src => $net->item($_[0]),
			dst => $nick,
			type => 'NICKINFO',
			item => 'swhois',
			value => $_[3],
		};
	}, AWAY => sub {
		my $net = shift;
		my $nick = $net->mynick($_[0]) or return ();
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
		my $nick = $net->mynick($_[0]) or return ();
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
		my $ts = $net->sjbint($_[2]);
		my $applied = ($chan->ts() >= $ts);
		my $joins = pop;
		my $cmode = $_[4] || '+';

		my @acts;

		push @acts, +{
			type => 'TIMESYNC',
			src => $net,
			dst => $chan,
			ts => $ts,
			oldts => $chan->ts(),
			wipe => 1,
		} if $chan->ts() > $ts;

		for (split /\s+/, $joins) {
			if (/^([&"'])(.+)/) {
				$cmode .= $1;
				push @_, $2;
			} else {
				/^([*~@%+]*)(.+)/ or warn;
				my $nmode = $1;
				my $nick = $net->mynick($2) or next;
				my %mh = map { tr/*~@%+/qaohv/; $net->cmode2txt($_) => 1 } split //, $nmode;
				push @acts, +{
					type => 'JOIN',
					src => $nick,
					dst => $chan,
					mode => ($applied ? \%mh : undef),
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
		} if $applied && @$modes;
		return @acts;
	}, PART => sub {
		my $net = shift;
		my $nick = $net->mynick($_[0]) or return ();
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
		my $src = $net->item($_[0]) or return ();
		my $chan = $net->item($_[2]) or return ();
		if ($chan->isa('Nick')) {
			# umode change
			return () unless $chan->homenet()->id() eq $net->id();
			return $net->_parse_umode($chan, @_[3 .. $#_]);
		}
		my @out;
		if ($src->isa('Network') && $_[-1] =~ /^(\d+)$/) {
			#TS update
			push @out, +{
				type => 'TIMESYNC',
				dst => $chan,
				ts => $1,
				oldts => $chan->ts(),
				wipe => 0,
			} if $1 && $1 < $chan->ts();
		}
		my $mode = $_[3];
		if ($mode =~ s/^&//) {
			# mode bounce: assume we are correct, and inform the server
			# that they are mistaken about whatever they think we have wrong. 
			# This is not very safe, but there's not much way around it
			$mode =~ y/+-/-+/;
			$net->send($net->cmd1(MODE => $_[2], $mode, @_[4 .. $#_]));
		}
		my($modes,$args) = $net->_modeargs($mode, @_[4 .. $#_]);
		push @out, {
			type => 'MODE',
			src => $src,
			dst => $chan,
			mode => $modes,
			args => $args,
		};
		@out;
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
		my $src = $_[0] ? $net->srvname($_[0]) : $net->cparam('linkname');
		my $name = lc $_[2];
		my $desc = $_[-1];

		my $snum = $net->sjb64((@_ > 5          ? $_[4] : 
				($desc =~ s/^U\d+-\S+-(\d+) //) ? $1    : 0), 1);

		print "Server $_[2] [\@$snum] added from $src\n";
		$servers[$$net]{$name} = {
			parent => lc $src,
			hops => $_[3],
			numeric => $snum,
		};
		$srvname[$$net]{$snum} = $name if $snum;

		$_[0] ? () : {
			type => 'BURST',
			net => $net,
			sendto => [],
		};
	}, SQUIT => sub {
		my $net = shift;
		my $netid = $net->id();
		my $srv = $net->srvname($_[2]);
		my $splitfrom = $servers[$$net]{lc $srv}{parent};
		
		my %sgone = (lc $srv => 1);
		my $k = 0;
		while ($k != scalar keys %sgone) {
			# loop to traverse each layer of the map
			$k = scalar keys %sgone;
			for (keys %{$servers[$$net]}) {
				$sgone{$_} = 1 if $sgone{$servers[$$net]{$_}{parent}};
			}
		}
		print 'Lost servers: '.join(' ', sort keys %sgone)."\n";
		delete $srvname[$$net]{$servers[$$net]{$_}{numeric}} for keys %sgone;
		delete $servers[$$net]{$_} for keys %sgone;

		my @quits;
		for my $nick ($net->all_nicks()) {
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
	PASS => sub {
		my $net = shift;
		if ($_[2] eq $net->cparam('recvpass')) {
			$auth[$$net] = 1;
		} else {
			$net->send('ERROR :Bad password');
		}
		();
	}, NETINFO => sub {
		my $net = shift;
		return +{
			type => 'LINKED',
			net => $net,
			sendto => [ values %Janus::nets ],
		};
	}, PROTOCTL => sub {
		my $net = shift;
		shift;
		print join ' ', @_, "\n";
		();
	}, 
	EOS => \&ignore,
	ERROR => sub {
		my $net = shift;
		&Janus::delink($net, 'ERROR: '.$_[-1]);
		();
	},

# Messages
	PRIVMSG => \&nc_msg,
	NOTICE => \&nc_msg,
	WHOIS => sub {
		my $net = shift;
		my $src = $net->item($_[0]);
		my @out;
		for my $n (split /,/, $_[3]) {
			my $dst = $net->item($n);
			next unless ref $dst && $dst->isa('Nick');
			push @out, +{
				type => 'WHOIS',
				src => $src,
				dst => $dst,
			};
		}
		@out;
	},
	HELP => \&ignore,
	SMO => \&ignore,
	SENDSNO => \&ignore,
	SENDUMODE => \&ignore,
	GLOBOPS => \&ignore,
	WALLOPS => \&ignore,
	NACHAT => \&ignore,
	ADMINCHAT => \&ignore,

	CHATOPS => sub {
		my $net = shift;
		return () unless $net->param('send_chatops');
		return +{
			type => 'CHATOPS',
			src => $net->item($_[0]),
			sendto => [ values %Janus::nets ],
			msg => $_[-1],
		};
	},
	TKL => sub {
		my $net = shift;
		my $iexpr;
		my $act = {
			type => 'BANLINE',
			src => $_[0],
			dst => $net,
			action => $_[2],
			setter => $_[6],
		};
		if ($_[2] eq '+') {
			$act->{expire} = $_[7];
			# 8 = set time
			$act->{reason} = $_[9];
		}
		if ($_[3] eq 'G') {
			$act->{ident} = $_[4] unless $_[4] eq '*';
			$act->{host} = $_[5] unless $_[5] eq '*';
		} elsif ($_[3] eq 'Q') {
			$act->{nick} = $_[5];
		} elsif ($_[3] eq 'Z') {
			$act->{ip} = $_[5];
		} else {
			# shun or spamfilter - confine these to local network
			return ();
		}
		$act;
	},
	SVSFLINE => \&ignore,
	TEMPSHUN => \&ignore,

	SAJOIN => \&ignore,
	SAPART => \&ignore,
	SVSJOIN => \&ignore,
	SVSLUSERS => \&ignore,
	SVSNOOP => \&ignore,
	SVSO => \&ignore,
	SVSSILENCE => \&ignore,
	SVSPART => \&ignore,
	SVSSNO => \&ignore,
	SVS2SNO => \&ignore,
	SVSWATCH => \&ignore,
	SQLINE => \&ignore,
	UNSQLINE => \&ignore,
	SVSREDIR => \&ignore,

	VERSION => sub {
		my $net = shift;
		my $nick = $net->mynick($_[0]) or return ();
		&Janus::jmsg($nick, '$Id$');
		return ();
	},
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
	CONNECT => \&todo,
	SDESC => \&todo,
	HTM => \&todo,
	RESTART => \&todo,
	REHASH => sub {
		return +{
			type => 'REHASH',
			sendto => [],
		};
	},
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
	$out .= exists $cmd2token{$cmd} ? $cmd2token{$cmd} : $cmd;
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
		if ($net->id() eq $id) {
			# first link to the net
			my @out;
			for $id (keys %Janus::nets) {
				$new = $Janus::nets{$id};
				next if $new->isa('Interface') || $id eq $net->id();
				push @out, $net->cmd2($net->cparam('linkname'), SERVER => "$id.janus", 2, $new->numeric(), $new->netname());
			}
			return @out;
		} else {
			return () if $net->isa('Interface');
			return $net->cmd2($net->cparam('linkname'), SERVER => "$id.janus", 2, $new->numeric(), $new->netname());
		}
	}, LINKED => sub {
		my($net,$act) = @_;
		my $new = $act->{net};
		my $id = $new->id();
		$net->cmd1(SMO => 'o', "(\002link\002) Janus Network $id (".$new->netname().') is now linked');
	}, NETSPLIT => sub {
		my($net,$act) = @_;
		my $gone = $act->{net};
		my $id = $gone->id();
		my $msg = $act->{msg} || 'Excessive Core Radiation';
		(
			$net->cmd1(SMO => 'o', "(\002delink\002) Janus Network $id (".$gone->netname().") has delinked: $msg"),
			$net->cmd1(SQUIT => "$id.janus", $msg),
		);
	}, CONNECT => sub {
		my($net,$act) = @_;
		my $nick = $act->{dst};
		return () if $act->{net}->id() ne $net->id();

		return $net->_connect_ifo($nick);
	}, RECONNECT => sub {
		my($net,$act) = @_;
		my $nick = $act->{dst};
		
		if ($act->{killed}) {
			my @out = $net->_connect_ifo($nick);
			for my $chan (@{$act->{reconnect_chans}}) {
				next unless $chan->is_on($net);
				my $mode = '';
				$chan->has_nmode($_, $nick) and $mode .= $net->txt2cmode($_) 
					for qw/n_voice n_halfop n_op n_admin n_owner/;
				$mode =~ tr/qaohv/*~@%+/;
				push @out, $net->cmd1(SJOIN => $net->sjb64($chan->ts()), $chan, $mode.$nick->str($net));
			}
			return @out;
		} else {
			return $net->cmd2($act->{from}, NICK => $act->{to}, $nick->ts());
		}
	}, JOIN => sub {
		my($net,$act) = @_;
		my $chan = $act->{dst};
		if ($act->{src}->homenet()->id() eq $net->id()) {
			print 'ERR: Trying to force channel join remotely ('.$act->{src}->gid().$chan->str($net).")\n";
			return ();
		}
		my $sj = '';
		if ($act->{mode}) {
			$sj .= $net->txt2cmode($_) for keys %{$act->{mode}};
		}
		$sj =~ tr/qaohv/*~@%+/;
		return () unless $act->{src}->is_on($net);
		$sj .= $net->_out($act->{src});
		[ JOIN => $net->sjb64($chan->ts()), $chan->str($net), $sj ];
	}, PART => sub {
		my($net,$act) = @_;
		$net->cmd2($act->{src}, PART => $act->{dst}, $act->{msg});
	}, KICK => sub {
		my($net,$act) = @_;
		$net->cmd2($act->{src}, KICK => $act->{dst}, $act->{kickee}, $act->{msg});
	}, MODE => sub {
		my($net,$act) = @_;
		my $src = $act->{src};
		my @interp = $net->_mode_interp($act->{mode}, $act->{args});
		return () unless @interp;
		return () if @interp == 1 && (!$interp[0] || $interp[0] =~ /^[+-]+$/);
		if (ref $src && $src->isa('Nick') && $src->is_on($net)) {
			return $net->cmd2($src, MODE => $act->{dst}, @interp);
		} else {
			return $net->cmd2($src, MODE => $act->{dst}, @interp, 0);
		}
	}, TIMESYNC => sub {
		my($net,$act) = @_;
		my $chan = $act->{dst};
		if ($act->{wipe}) {
			if ($act->{ts} == $act->{oldts}) {
				my @interp = $net->_mode_interp($chan->mode_delta());
				return $net->cmd1(MODE => $chan, @interp, 0);
			} else {
				return $net->cmd1(SJOIN => $net->sjb64($act->{ts}), $chan, '+', '');
			}
		} else {
			return $net->cmd1(MODE => $chan, '+', $act->{ts});
		}
	}, TOPIC => sub {
		my($net,$act) = @_;
		$net->cmd2($act->{src}, TOPIC => $act->{dst}, $act->{topicset}, 
			$net->sjb64($act->{topicts}), $act->{topic});
	}, MSG => sub {
		my($net,$act) = @_;
		return if $act->{dst}->isa('Network');
		my $type = $act->{msgtype} || 'PRIVMSG';
		# only send things we know we should be able to get through to the client
		return () unless $type eq 'PRIVMSG' || $type eq 'NOTICE' || $type =~ /^\d\d\d$/;
		my @msg = ref $act->{msg} eq 'ARRAY' ? @{$act->{msg}} : $act->{msg};
		[ FLOAT_ALL => $net->cmd2($act->{src}, $type, ($act->{prefix} || '').$net->_out($act->{dst}), @msg) ];
	}, WHOIS => sub {
		my($net,$act) = @_;
		my $dst = $act->{dst};
		$net->cmd2($act->{src}, WHOIS => $dst, $dst);
	}, CHATOPS => sub {
		my($net,$act) = @_;
		return () unless $act->{src}->is_on($net);
		$net->cmd2($act->{src}, CHATOPS => $act->{msg});
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
			next if $skip_umode{$txt};
			next if $txt eq 'hideoper' && !$net->param('show_roper');
			if ($pm ne $d) {
				$pm = $d;
				$mode .= $pm;
			}
			$mode .= $txt2umode{$txt};
		}
		$mode =~ s/o/oH/ unless $net->param('show_roper');

		return () unless $mode;
		$net->cmd2($act->{dst}, UMODE2 => $mode);
	}, QUIT => sub {
		my($net,$act) = @_;
		return () if $act->{netsplit_quit};
		return () unless $act->{dst}->is_on($net);
		$net->cmd2($act->{dst}, QUIT => $act->{msg});
	}, LINK => sub {
		my($net,$act) = @_;
		my $chan = $act->{dst}->str($net);
		return () if $act->{linkfile};
		[ FLOAT_ALL => $net->cmd1(GLOBOPS => "Channel $chan linked") ];
	}, LSYNC => sub {
		();
	}, LINKREQ => sub {
		my($net,$act) = @_;
		my $src = $act->{net};
		return () if $act->{linkfile};
		[ FLOAT_ALL => $net->cmd1(GLOBOPS => $src->netname()." would like to link $act->{slink} to $act->{dlink}") ];
	}, DELINK => sub {
		my($net,$act) = @_;
		return () if $act->{netsplit_quit};
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
	}, PING => sub {
		my($net,$act) = @_;
		$net->cmd1(PING => $net->cparam('linkname'));
	},
);

1;
