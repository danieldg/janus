# Copyright (C) 2007-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Server::Inspircd_1200;
use Nick;
use Modes;
use Server::BaseUID;
use Server::ModularNetwork;
use Server::InspMods;
use Util::Crypto;

use Persist 'Server::BaseUID', 'Server::ModularNetwork';
use strict;
use warnings;
use integer;

our(@sendq1, @sendq2, @servers, @serverdsc, @servernum, @next_uid, @capabs);
Persist::register_vars(qw(sendq1 sendq2 servers serverdsc servernum next_uid capabs));

sub _init {
	my $net = shift;
	$sendq1[$$net] = '';
	$sendq2[$$net] = '';
	$net->module_add('CORE');
}

sub ignore { () }

sub nicklen {
	my $net = shift;
	($capabs[$$net]{NICKMAX} || 32) - 1;
}

sub str {
	my $net = shift;
	$net->jname();
}

sub intro {
	my($net,@param) = @_;
	$net->SUPER::intro(@param);
	my @out;
	$sendq1[$$net] .= "CAPAB START\r\n";
	# we cannot continue until we get the remote CAPAB list so we can
	# forge the module list. However, we can set up the other server introductions
	# as they will be sent after auth is done
	$net->send($net->ncmd(VERSION => 'Janus Hub'));
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
	unless ($net->auth_ok || $cmd eq 'CAPAB' || $cmd eq 'SERVER' || $cmd eq 'ERROR') {
		$sendq1[$$net] .= "ERROR :Not authorized yet\r\n";
		return ();
	}
	$net->from_irc(@args);
}

sub send {
	my $net = shift;
	my @q = $net->to_irc(@_);
	$sendq2[$$net] .= join '', map "$_\r\n", @q;
}

sub dump_sendq {
	my $net = shift;
	local $_;
	my $q = $sendq1[$$net];
	$sendq1[$$net] = '';
	Log::netout($net, $_) for split /\r\n/, $q;
	if ($net->auth_ok) {
		my $fj_pfx;
		my $fj_line = '';
		my @lines = split /\r\n/, $sendq2[$$net];
		$sendq2[$$net] = '';
		for (@lines) {
			if (/^:\S+ FJOIN (.*?) :(.*)/) {
				if ($fj_line && $fj_pfx eq $1 && length $fj_line < 490) {
					$fj_line .= ' '.$2;
				} else {
					$q .= $fj_line."\r\n" if $fj_line;
					Log::netout($net, $fj_line) if $fj_line;
					$fj_pfx = $1;
					$fj_line = $_;
				}
			} else {
				if ($fj_line && !/^:\S+ UID /) {
					$q .= $fj_line."\r\n";
					Log::netout($net, $fj_line);
					$fj_line = '';
				}
				$q .= $_ . "\r\n";
				Log::netout($net, $_) unless /^:\S+ (?:PRIVMSG|NOTICE) /;
			}
		}
		$q .= $fj_line."\r\n" if $fj_line;
		Log::netout($net, $fj_line) if $fj_line;
	}
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

sub collide_winner {
	my($net,$old,$new) = @_;
	my $tsctl = $old->ts($net) <=> $new->ts($net);

	if ($new->info('ident') eq $old->info('ident') && $new->info('ip') eq $old->info('ip')) {
		# this is a ghosting nick, we REVERSE the normal timestamping
		$tsctl = -$tsctl;
	}
	$tsctl;
}

sub _connect_ifo {
	my ($net, $nick) = @_;

	my @out;

	my $mode = '+';
	my @modearg;
	for my $m ($nick->umodes()) {
		my $um = $net->txt2umode($m);
		next unless defined $um;
		if (ref $um) {
			$mode .= $um->($net, $nick, '+'.$m, \@out, \@modearg);
		} else {
			$mode .= $um;
		}
	}

	my $ip = $nick->info('ip') || '0.0.0.0';
	$ip = '0.0.0.0' if $ip eq '*' || $net->param('untrusted');
	if ($nick->has_mode('oper')) {
		my $type = $nick->info('opertype') || 'IRC Operator';
		my $visible = Setting::get(oper_visibility => $net);
		$visible = 3 if $nick == $Interface::janus;
		my $suffix = $visible < 3 ? ' (remote)' : '';
		if ($visible == 1) {
			my $ho = $net->txt2umode('hideoper');
			$mode .= $ho if defined $ho && -1 == index $mode, $ho;
		}
		my $len = $net->nicklen() - length $suffix;
		$type = substr($type, 0, $len).$suffix;
		$type =~ s/ /_/g;
		push @out, $net->cmd2($nick, OPERTYPE => $type) if $visible;
	}
	push @out, $net->cmd2($nick, AWAY => $nick->info('away')) if $nick->info('away');
	my $host = $nick->info($net->param('untrusted') ? 'vhost' : 'host');
	unshift @out, $net->cmd2($nick->homenet, UID => $nick, $nick->ts($net), $nick->str($net),
		$host, $nick->info('vhost'), $nick->info('ident'), $ip, ($nick->info('signonts') || 1),
		$mode, @modearg, $nick->info('name'));

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
	# Other maxima are not required to be enforced
	# IP6NATIVE=1 IP6SUPPORT=1 - we currently require IPv6 support, and claim to be native because we're cool like that :)
	# PROTOCOL=1201
	$capabs[$$net]{IP6SUPPORT} = 1;
	warn "I don't know how to read protocol $capabs[$$net]{PROTOCOL}"
		unless $capabs[$$net]{PROTOCOL} == 1200 || $capabs[$$net]{PROTOCOL} == 1201;

	# PREFIX=(qaohv)~&@%+ - just get the letters
	$capabs[$$net]{PREFIX} =~ /\((\S+)\)\S+/ or warn;
	my $pfxmodes = $1;
	my $expect = Modes::modelist($net, $pfxmodes);
	unless ($expect eq $capabs[$$net]{CHANMODES}) {
		$net->send($net->ncmd(SNONOTICE => 'l', 'Possible desync - CHANMODES do not match module list: '.
			"expected $expect, got $capabs[$$net]{CHANMODES}"));
	}
	for (split //, $pfxmodes) {
		my $t = $net->cmode2txt($_);
		next if $t && $t =~ /^n_/;
		$net->send($net->ncmd(SNONOTICE => 'l', "Possible desync - PREFIX does not include mode '$_'"));
	}

	$expect = '';
	for ('0'..'9','A'..'Z','a'..'z') {
		$expect .= $_ if defined $net->umode2txt($_, 1);
	}
	$expect =~ s/s//;
	my $given = $capabs[$$net]{USERMODES};
	unless (",,s,$expect" eq $given) {
		$net->send($net->ncmd(SNONOTICE => 'l', 'Possible desync - USERMODES do not match module list: '.
			"expected ,,s,$expect, got $given"));
	}

	my $chall = delete $capabs[$$net]{CHALLENGE};
	my $sha2 = eval { require Digest::SHA; Digest::SHA->new('sha256') };
	if ($chall && $sha2) {
		$capabs[$$net]{' HMAC_SPASS'} = 'HMAC-SHA256:'.Util::Crypto::hmac_inspircd12_style($sha2, $net->cparam('sendpass'), $chall);

		$chall = Util::Crypto::salt(20, $net, $chall);
		$capabs[$$net]{CHALLENGE} = $chall;

		$capabs[$$net]{' HMAC_RPASS'} = 'HMAC-SHA256:'.Util::Crypto::hmac_inspircd12_style($sha2, $net->cparam('recvpass'), $chall);
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
		's', '',
  },
  cmds => {
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
			}, {
				type => 'RAW',
				dst => $net,
				msg => $net->ncmd(SVSNICK => $nick, $_[2], $ts),
			};
			# TODO only send the SVSNICK if needed
		}

		push @out, {
			type => 'NICK',
			src => $nick,
			dst => $nick,
			nick => $_[2],
			nickts => $ts,
		};
		@out;
	}, UID => sub {
		my $net = shift;
		my $ip = $_[8];
		my $srvname = $servernum[$$net]{$_[0]} || $_[0];
		my %nick = (
			net => $net,
			ts => $_[3],
			nick => $_[4],
			info => {
				home_server => $srvname,
				host => $_[5],
				vhost => $_[6],
				ident => $_[7],
				signonts => $_[9],
				ip => $ip,
				name => $_[-1],
			},
		);
		my @m = split //, $_[10];
		warn unless '+' eq shift @m;
		$nick{mode} = +{ map {
			my $t = $net->umode2txt($_);
			$t ? ($t => 1) : ();
		} @m };

		my $nick = Nick->new(%nick);
		$net->register_nick($nick, $_[2]);
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
			$nm =~ /^(.*),(\S+)$/ or next;
			my $nmode = $1;
			my $nick = $net->mynick($2) or next;
			my %mh = map {
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
		my($modes,$args,$dirs) = Modes::from_irc($net, $chan, @_[4 .. $#_]);
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
			return () unless $dst->homenet() eq $net;
			$net->_parse_umode($dst, $_[3]);
		} else {
			my($modes,$args,$dirs) = Modes::from_irc($net, $dst, @_[3 .. $#_]);
			return +{
				type => 'MODE',
				src => $src,
				dst => $dst,
				mode => $modes,
				args => $args,
				dirs => $dirs,
			};
		}
	}, FTOPIC => sub {
		my $net = shift;
		my $chan = $net->chan($_[2]) or return ();
		return +{
			type => 'TOPIC',
			src => $net->item($_[0]),
			dst => $chan,
			topicts => $_[3],
			topicset => $_[4],
			topic => $_[-1],
			in_link => 1,
		};
	}, TOPIC => sub {
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
			timeout => $_[4],
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
			Log::debug_in($net, "Introducing server $_[2] from $_[0] with numeric $_[5]");
			$servers[$$net]{CORE::lc $_[2]} = $_[0] =~ /^\d/ ? $servernum[$$net]{$_[0]} : CORE::lc $_[0];
			$serverdsc[$$net]{CORE::lc $_[2]} = $_[-1];
			$servernum[$$net]{$_[5]} = $_[2];
			return ();
		} else {
			Log::debug_in($net, "Initial server introduction of $_[2] with numeric $_[5]");
			my $rpass = delete $capabs[$$net]{' HMAC_RPASS'} || $net->cparam('recvpass');
			if ($_[3] eq $rpass) {
				$net->auth_recvd;
				if ($net->auth_should_send) {
					my $spass = delete $capabs[$$net]{' HMAC_SPASS'} || $net->cparam('sendpass');
					my $name = $net->cparam('linkname') || $RemoteJanus::self->jname;
					$sendq1[$$net] .= $net->cmd2(undef, SERVER => $name, $spass, 0, $net, "Janus Network Link\r\n");
				}
				$sendq1[$$net] .= $net->ncmd(BURST => $Janus::time)."\r\n";
			} else {
				$sendq1[$$net] .= "ERROR :Bad password\r\n";
				return ();
			}
			$serverdsc[$$net]{CORE::lc $_[2]} = $_[-1];
			$servernum[$$net]{$_[5]} = $_[2];
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
		my $net = shift;
		my $src = $net->mynick($_[0]) or return ();
		$_[2] =~ /^(\S+)\.janus$/ or return ();
		my $dst = $1;
		{
			type => 'MSG',
			src => $src,
			dst => $Interface::janus,
			msgtype => 'PRIVMSG',
			msg => "NETSPLIT $dst",
		};
	}, PING => sub {
		my $net = shift;
		my $from = $_[3] || $net;
		$net->send($net->cmd2($from, 'PONG', $from, $_[2]));
		();
	},
	PONG => \&ignore,
	BURST => \&ignore,
	CAPAB => sub {
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
				$_ .'='. $capabs[$$net]{$_};
			} grep !/ /, keys %{$capabs[$$net]};

			my @out;
			push @out, 'CAPAB MODULES '.$1 while $mods =~ s/(.{1,495})(,|$)//;
			push @out, 'CAPAB CAPABILITIES :'.$1 while $capabs =~ s/(.{1,450})( |$)//;
			push @out, 'CAPAB END';
			if ($net->auth_should_send) {
				my $spass = delete $capabs[$$net]{' HMAC_SPASS'} || $net->cparam('sendpass');
				my $name = $net->cparam('linkname') || $RemoteJanus::self->jname;
				push @out, $net->cmd2(undef, SERVER => $name, $spass, 0, $net, 'Janus Network Link');
			}
			$sendq1[$$net] .= join "\r\n", @out, '';
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
	DELLINE => sub {
		my $net = shift;
		return +{
			type => 'XLINE',
			dst => $net,
			ltype => $_[2],
			mask => $_[3],
			setter => $_[0],
			expire => 1,
		};
	},

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
		my $ts = $_[4];
		if ($nick->homenet == $net) {
			Log::debug_in($net, "Misdirected SVSNICK ignored");
			return ();
		} elsif ($ts >= $nick->ts($net)) {
			return +{
				type => 'RECONNECT',
				src => $net->item($_[0]),
				dst => $nick,
				net => $net,
				killed => 0,
				altnick => 1,
			};
		} else {
			$net->send($net->cmd2($nick, NICK => $nick->str($net), $nick->ts($net)));
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
		if ($_[0]) {
			my $srv = $servernum[$$net]{$_[0]};
			return () if $servers[$$net]{CORE::lc $srv};
			# remote burst
		} else {
			Log::warn_in($net, 'Source-less ENDBURST received!');
		}
		return (+{
			type => 'LINKED',
			net => $net,
		}, +{
			type => 'RAW',
			dst => $net,
			msg => $net->ncmd('ENDBURST'),
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
	NOTICE => 'PRIVMSG',
	MODENOTICE => \&ignore,
	SNONOTICE => \&ignore,
	WALLOPS => \&ignore,
	RCONNECT => \&ignore,
	MAP => \&ignore,
	STATS => \&ignore,
	METADATA => sub {
		my $net = shift;
		my $key = $_[3];
		$net->do_meta($key, @_);
	},
	ENCAP => sub {
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
  }, acts => {
	JNETLINK => sub {
		my($net,$act) = @_;
		my $new = $act->{net};
		my $jid = $new->id().'.janus';
		($net->ncmd(SERVER => $jid, '*', 1, $new, 'Inter-Janus link'),
		 $net->cmd2($new, VERSION => 'Interjanus'));
	}, NETLINK => sub {
		my($net,$act) = @_;
		my $new = $act->{net};
		my @out;
		if ($net eq $new) {
			for my $ij (values %Janus::ijnets) {
				next unless $ij->is_linked();
				next if $ij eq $RemoteJanus::self;
				my $jid = $ij->id().'.janus';
				push @out, $net->ncmd(SERVER => $jid, '*', 1, $ij, 'Inter-Janus link');
				push @out, $net->cmd2($ij, VERSION => 'Interjanus');
			}
			for my $id (keys %Janus::nets) {
				my $new = $Janus::nets{$id};
				next if $new->isa('Interface') || $new eq $net;
				my $jl = $new->jlink();
				if ($jl) {
					push @out, $net->cmd2($jl, SERVER => $new->jname(), '*', 2, $new, $new->netname());
				} else {
					push @out, $net->ncmd(SERVER => $new->jname(), '*', 1, $new, $new->netname());
				}
				push @out, $net->cmd2($new, VERSION => 'Remote Janus Server: '.$new->type);
			}
		} else {
			my $jl = $new->jlink();
			if ($jl) {
				push @out, $net->cmd2($jl, SERVER => $new->jname(), '*', 2, $new, $new->netname());
			} else {
				push @out, $net->ncmd(SERVER => $new->jname(), '*', 1, $new, $new->netname());
			}
			push @out, $net->cmd2($new, VERSION => 'Remote Janus Server: '.$new->type);
		}
		return @out;
	}, LINKED => sub {
		my($net,$act) = @_;
		$net->cmd2($act->{net}, 'ENDBURST');
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
	}, CONNECT => sub {
		my($net,$act) = @_;
		my $nick = $act->{dst};
		return () if $act->{net} ne $net;
		my @out = $net->_connect_ifo($nick);
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
					$chan->has_nmode($_, $nick) ? ($net->txt2cmode("n_$_") || '') : ''
				} qw/voice halfop op admin owner/;
				my @cmodes = Modes::to_multi($net, Modes::dump($chan), $capabs[$$net]{MAXMODES});
				@cmodes = (['+']) unless @cmodes && @{$cmodes[0]};
				warn "w00t said this wouldn't happen" if @cmodes != 1;

				push @out, $net->ncmd(FJOIN => $chan, $chan->ts(), @{$cmodes[0]}, $mode.','.$nick->str($net));
			}
			return @out;
		} else {
			return $net->cmd2($nick, NICK => $act->{to}, $nick->ts($net));
		}
	}, NICK => sub {
		my($net,$act) = @_;
		my $id = $$net;
		my $dst = $act->{dst};
		$net->cmd2($dst, NICK => $act->{to}{$id}, $dst->ts($net));
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
		}
		my @cmodes = Modes::to_multi($net, Modes::dump($chan), $capabs[$$net]{MAXMODES});
		@cmodes = (['+']) unless @cmodes && @{$cmodes[0]};
		warn "w00t said this wouldn't happen" if @cmodes != 1;

		$net->ncmd(FJOIN => $chan, $chan->ts(), @{$cmodes[0]}, $mode.','.$net->_out($act->{src}));
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
		my @modes = Modes::to_multi($net, $act->{mode}, $act->{args}, $act->{dirs},
			$capabs[$$net]{MAXMODES});
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
			my @out;
			my $mch = '-o';
			my $suffix = $visible < 3 ? ' (remote)' : '';
			if ($visible == 1 && $net->txt2umode('hideoper')) {
				push @out, $net->cmd2($act->{dst}, MODE => $act->{dst}, '+H');
			}
			my $len = $net->nicklen() - length $suffix;
			my $type = substr($act->{value}, 0, $len).$suffix;
			unshift @out, $net->cmd2($act->{dst}, OPERTYPE => $type);
			return @out;
		}
		return ();
	}, CHANTSSYNC => sub {
		my($net,$act) = @_;
		my $chan = $act->{dst};
		my $ts = $act->{newts};

		my @sjmodes = Modes::to_irc($net, Modes::dump($chan));
		@sjmodes = '+' unless @sjmodes;

		my @out = $net->ncmd(FJOIN => $chan, $ts, @sjmodes, ','.$net->_out($Interface::janus));

		push @out, map {
			$net->ncmd(FMODE => $chan, $ts, @$_);
		} Modes::to_multi($net, Modes::delta(undef, $chan, $net, 1), $capabs[$$net]{MAXMODES});

		@out;
	}, CHANBURST => sub {
		my($net,$act) = @_;
		my $old = $act->{before};
		my $new = $act->{after};
		my @sjmodes = Modes::to_irc($net, Modes::dump($new));
		@sjmodes = '+' unless @sjmodes;
		my @out;
		push @out, $net->ncmd(FJOIN => $new, $new->ts, @sjmodes, ','.$net->_out($Interface::janus));
		push @out, map {
			$net->ncmd(FMODE => $new, $new->ts, @$_);
		} Modes::to_multi($net, Modes::delta($new->ts < $old->ts ? undef : $old, $new), $capabs[$$net]{MAXMODES});
		if ($new->topic && (!$old->topic || $old->topic ne $new->topic)) {
			push @out, $net->ncmd(FTOPIC => $new, $new->topicts, $new->topicset, $new->topic);
		}
		@out;
	}, CHANALLSYNC => sub {
		my($net,$act) = @_;
		my $chan = $act->{chan};
		my @sjmodes = Modes::to_irc($net, Modes::dump($chan));
		@sjmodes = '+' unless @sjmodes;
		my @out;
		my $fj = '';
		# TODO this likely misses +qa if people turn off prefix mode for them
		for my $nick ($chan->all_nicks) {
			my $mode = $chan->get_nmode($nick);
			my $m = join '', map { $net->txt2cmode("n_$_") || '' } keys %$mode;
			$fj .= ' '.$m.','.$net->_out($nick);
		}
		$fj =~ s/^ // or return ();
		push @out, $net->ncmd(FJOIN => $chan, $chan->ts, @sjmodes, $fj);
		push @out, map {
			$net->ncmd(FMODE => $chan, $chan->ts, @$_);
		} Modes::to_multi($net, Modes::delta(undef, $chan), $capabs[$$net]{MAXMODES});
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
		my $src = $act->{src};
		$src = $src->homenet if $src->isa('Nick') && !$src->is_on($net);
		if ($type eq 'PRIVMSG' || $type eq 'NOTICE') {
			return $net->cmd2($src, $type, $dst, $act->{msg});
		} elsif ($act->{dst}->isa('Nick')) {
			# sent to a single user - just PUSH the result
			my $msg = $net->cmd2($src, $type, $dst, ref $act->{msg} eq 'ARRAY' ? @{$act->{msg}} : $act->{msg});
			return $net->ncmd(PUSH => $act->{dst}, $msg);
		}
		return ();
	}, WHOIS => sub {
		my($net,$act) = @_;
		$net->cmd2($act->{src}, IDLE => $act->{dst});
	}, PING => sub {
		my($net,$act) = @_;
		$net->ncmd(PING => $net);
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
