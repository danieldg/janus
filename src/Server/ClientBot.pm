# Copyright (C) 2007-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Server::ClientBot;
use LocalNetwork;
use Nick;
use Modes;
use Server::BaseNick;
use Persist 'Server::BaseNick';
use Scalar::Util 'weaken';
use strict;
use warnings;
use integer;
use Link;

our(@sendq, @self, @cmode2txt, @txt2cmode, @capabs);
our(@flood_bkt, @flood_ts, @half_in, @half_out);
Persist::register_vars(qw(sendq self cmode2txt txt2cmode capabs flood_bkt flood_ts half_in half_out));
# half_in = Part of a multi-line response that will be processed later
#  [ 'TOPIC', channel, topic ]
# half_out = Currently queued commands going out. List of lists.
#  [ TS, raw-line, ID, ... ]

my %fromirc;
my %toirc;

sub ignore { () }

sub shift_halfout {
	my $n = shift;
	shift @{$half_out[$$n]};
	if (@{$half_out[$$n]}) {
		$half_out[$$n][0][0] += $Janus::time;
		$n->send($half_out[$$n][0][1]);
	}
}

sub add_halfout {
	my($n, $cmd) = @_;
	push @{$half_out[$$n]}, $cmd;
	if (@{$half_out[$$n]} == 1) {
		$half_out[$$n][0][0] += $Janus::time;
		$n->send($half_out[$$n][0][1]);
	}
}

sub poll_halfout {
	my $n = shift;
	my $evt = $half_out[$$n][0] or return;
	my $t = $evt->[0];
	return if $t > $Janus::time;
	if ($evt->[2] eq 'KICK') {
		my $chan = $n->chan($evt->[3]);
		my $nick = $evt->[4];
		if ($nick && $chan) {
			Log::debug_in($n, 'Unkicking '.$nick->str($n).' from '.$evt->[3]);
			Event::insert_full(+{
				type => 'JOIN',
				src => $nick,
				dst => $chan,
			});
		}
	} elsif ($evt->[2] eq 'USER') {
		Log::warn_in($n, 'Timeout on initial introduction, high lag?');
		$n->process_capabs();
	}
	$n->shift_halfout();
}

sub invisquit {
	my $e = shift;
	my $nick = $e->{nick} or return;
	return if $nick->all_chans;
	my $net = $nick->homenet;
	for my $i (0..$#{$half_out[$$net]}) {
		my $curr = $half_out[$$net][$i];
		return if $curr->[2] eq 'KICK' && $curr->[4] && $curr->[4] == $nick;
	}
	Event::insert_full(+{
		type => 'QUIT',
		dst => $nick,
		msg => 'Janus relay bot cannot see this nick',
	});
}

sub intro {
	my($net,$param) = @_;
	$net->SUPER::intro($param);
	if ($net->cparam('linktype') eq 'tls') {
		$net->add_halfout([ 15, 'STARTTLS', 'TLS' ]);
	}
	$net->add_halfout([ 90, "USER mirror gamma * :Janus IRC Client\r\nNICK $param->{nick}", 'USER' ]);
	$self[$$net] = $param->{nick};
	$flood_bkt[$$net] = Setting::get(tbf_burst => $net);
	$flood_ts[$$net] = $Janus::time;
}

my %def_c2t = (qw/
	q n_op
	a n_op
	o n_op
	h n_halfop
	v n_voice

	b l_ban
	e l_except
	I l_invite
	l s_limit
	i r_invite
	m r_moderated
	n r_mustjoin
	p t1_chanhide
	s t2_chanhide
	t r_topic
/);

my %def_t2c;
$def_t2c{$def_c2t{$_}} = $_ for keys %def_c2t;
$def_t2c{n_op} = 'o';

sub _init {
	my $net = shift;
	$sendq[$$net] = [];
	$half_out[$$net] = [];
	$capabs[$$net] = {
		MODES => 4,
	};
	$cmode2txt[$$net] = \%def_c2t;
	$txt2cmode[$$net] = \%def_t2c;
}

sub process_capabs {
	my $net = shift;
	my(@g,@ltype,@ttype);
	if ($capabs[$$net]{CHANMODES} && $capabs[$$net]{CHANMODES} =~ /^([^,]*),([^,]*),([^,]*),([^,]*)$/) {
		@g = ($1,$2,$3,$4);
		@ltype = qw(l v s r);
		@ttype = qw(l v v r);
	}
	if ($capabs[$$net]{PREFIX} && $capabs[$$net]{PREFIX} =~ /^\(([^()]+)\)/) {
		push @g, $1;
		push @ltype, 'n';
		push @ttype, 'n';
	}
	if (@g == 5) {
		my %c2t;
		my %t2c;
		for my $i (0..$#g) {
			for (split //, $g[$i]) {
				my $name = $ltype[$i].'__'.$ttype[$i].($_ eq lc $_ ? 'l' : 'u').(lc $_);

				my $def = $def_c2t{$_};
				if ($def && $def =~ /^._(.*)/ && Modes::mtype($1) eq $ttype[$i]) {
					$name = $ltype[$i].'_'.$1;
				}

				$c2t{$_} = $name;
				$t2c{$name} = $_;
			}
		}
		$t2c{n_op} = 'o';
		$txt2cmode[$$net] = \%t2c;
		$cmode2txt[$$net] = \%c2t;
	} else {
		Log::warn_in($net, 'No 005 CHANMODES/PREFIX, assuming RFC1459 modes');
	}
	my $um = $capabs[$$net]{' umodes'} || '';
	$net->send('PROTOCTL NAMESX') if $capabs[$$net]{NAMESX};
	$net->send("MODE ".$self[$$net].' +B') if $um =~ /B/;
}

sub cmode2txt {
	$cmode2txt[${$_[0]}]{$_[1]};
}
sub txt2cmode {
	$txt2cmode[${$_[0]}]{$_[1]};
}

sub cli_hostintro {
	my($net, $nname, $ident, $host, $gecos) = @_;
	my @out;
	my $nick = $net->item($nname);
	return () if $nick && $nick == $Interface::janus;

	unless ($nick && $nick->homenet == $net) {
		my $ts = $Janus::time;
		if ($nick) {
			# someone already exists, but remote. They get booted off their current nick
			Event::insert_full({
				type => 'RECONNECT',
				dst => $nick,
				net => $net,
				killed => 0,
				altnick => 1,
			});
		}
		$nick = Nick->new(
			net => $net,
			ts => $ts,
			nick => $nname,
			info => {
				signonts => $Janus::time,
				host => $host,
				vhost => $host,
				ident => $ident,
				name => (defined $gecos ? $gecos : 'MirrorServ Client'),
			},
			mode => {
				invisible => 1,
			},
		);
		my $evt = {
			delay => 15,
			net => $net,
			nick => $nick,
			code => \&invisquit,
		};
		weaken($evt->{net});
		weaken($evt->{nick});
		Event::schedule($evt);

		$net->request_nick($nick, $nname);
		push @out, +{
			type => 'NEWNICK',
			dst => $nick,
		};
		unless (defined $gecos) {
			$net->add_halfout([ 10, "WHO $nname", 'WHO/N', $nname ]);
		}
	}
	if ($nick->info('vhost') ne $host) {
		push @out, +{
			type => 'NICKINFO',
			src => $nick,
			dst => $nick,
			item => 'vhost',
			value => $host,
		};
	}
	if ($nick->info('ident') ne $ident) {
		push @out, +{
			type => 'NICKINFO',
			src => $nick,
			dst => $nick,
			item => 'ident',
			value => $ident,
		};
	}
	if (defined $gecos && $nick->info('name') ne $gecos) {
		push @out, +{
			type => 'NICKINFO',
			src => $nick,
			dst => $nick,
			item => 'name',
			value => $gecos,
		};
	}
	@out;
}

# parse one line of input
sub parse {
	my ($net, $line) = @_;
	my @out;
	Log::netin(@_);
	my ($txt, $msg) = split /\s+:/, $line, 2;
	my @args = split /\s+/, $txt;
	push @args, $msg if defined $msg;
	if ($args[0] =~ /^:([^ !]+)!([^ @]+)@(\S+)/) {
		$args[0] = $1;
		push @out, $net->cli_hostintro($1, $2, $3);
	} elsif ($args[0] =~ /^:/) {
		$args[0] = undef;
	} else {
		unshift @args, undef;
	}
	my $cmd = $args[1];
	$cmd = $fromirc{$cmd} || $cmd;
	unless (ref $cmd) {
		Log::warn_in($net, "Unknown command in line $line");
		return ();
	}
	push @out, $cmd->($net,@args);
	@out;
}

sub send {
	my $net = shift;
	for my $act (@_) {
		if (ref $act) {
			my $type = $act->{type};
			next unless $toirc{$type};
			push @{$sendq[$$net]}, $toirc{$type}->($net,$act);
		} else {
			push @{$sendq[$$net]}, $act;
		}
	}
}

sub _out {
	my($net,$itm) = @_;
	return '' unless defined $itm;
	return $itm unless ref $itm;
	if ($itm->isa('Nick')) {
		return $itm->str($net) if $itm->is_on($net);
		return $itm->homenet()->jname();
	} elsif ($itm->isa('Channel')) {
		return $itm->str($net);
	} elsif ($itm->isa('Network')) {
		return $itm->jname();
	} else {
		Log::warn_in($net,"Unknown item $itm");
		return '';
	}
}

sub cmd1 {
	my $net = shift;
	my $out = shift;
	if (@_) {
		my $end = $net->_out(pop @_);
		$out .= ' '.$net->_out($_) for @_;
		$out .= ' :'.$end;
	}
	$out;
}

Event::setting_add({
	name => 'tbf_rate',
	type => __PACKAGE__,
	help => 'Flood rate (lines/second)',
	default => 3,
}, {
	name => 'tbf_burst',
	type => __PACKAGE__,
	help => 'Flood burst length (lines)',
	default => 20,
}, {
	name => 'kick_rejoin',
	type => __PACKAGE__,
	help => 'Automatically rejoin channel when kicked (0|1)',
	default => 1,
});

sub dump_sendq {
	my $net = shift;
	local $_;
	$net->poll_halfout();
	my $tokens = $flood_bkt[$$net];
	my $rate = Setting::get(tbf_rate => $net);
	my $max = Setting::get(tbf_burst => $net);
	$tokens += ($Janus::time - $flood_ts[$$net])*$rate;
	$tokens = $max if $tokens > $max;
	my $q = '';
	while ($tokens && @{$sendq[$$net]}) {
		my $line = shift @{$sendq[$$net]};
		$q .= $line . "\r\n";
		Log::netout($net, $line);
		$tokens--;
	}
	$flood_ts[$$net] = $Janus::time;
	$flood_bkt[$$net] = $tokens;
	$q;
}

sub request_newnick {
	my($net, $nick, $reqnick, $tag) = @_;
	$reqnick = $self[$$net] if $nick == $Interface::janus;
	Server::BaseNick::request_nick($net, $nick, $reqnick, $tag);
}

sub request_cnick {
	my($net, $nick, $reqnick, $tag) = @_;
	$reqnick = $self[$$net] if $nick == $Interface::janus;
	Server::BaseNick::request_cnick($net, $nick, $reqnick, $tag);
}

sub delink_cancel_join {
	my $net = shift;
	my $curr = $half_out[$$net][0];
	if ($curr && $curr->[2] eq 'JOIN' && lc $_[3] eq lc $curr->[3]) {
		$net->shift_halfout();
	}
	my $chan = $net->chan($_[3]) or return ();
	return +{
		type => 'DELINK',
		cause => 'unlink',
		dst => $chan,
		net => $net,
	};
}

sub nicklen { 40 }

%toirc = (
	JOIN => sub {
		my($net,$act) = @_;
		my $src = $act->{src};
		my $dst = $act->{dst};
		if ($src == $Interface::janus) {
			my $chan = $dst->str($net);
			$net->add_halfout([ 10, "JOIN $chan", 'JOIN', $chan ]);
			();
		} else {
			return () unless $dst->get_mode('cb_showjoin');
			my $id = $src->str($net).'!'.$src->info('ident').'@'.$src->info('vhost');
			$net->cmd1(NOTICE => $dst, "Join: $id");
		}
	},
	DELINK => sub {
		my($net,$act) = @_;
		return () unless $net == $act->{net};
		my $dst = $act->{split};
		my @bye;
		for my $nick ($dst->all_nicks) {
			next unless $nick->homenet == $net;
			my @chans = $nick->all_chans();
			if (!@chans || (@chans == 1 && $chans[0] == $dst)) {
				push @bye, {
					type => 'QUIT',
					dst => $nick,
					msg => 'Relay bot parted channel',
				};
			} else {
				push @bye, {
					type => 'PART',
					src => $nick,
					dst => $dst,
					msg => 'Relay bot parted channel',
				};
			}
		}
		Event::append(@bye);
		();
	},
	PART => sub {
		my($net,$act) = @_;
		my $src = $act->{src};
		my $dst = $act->{dst};
		if ($src == $Interface::janus) {
			my $chan = $dst->str($net);
			"PART $chan :$act->{msg}";
		} else {
			return () unless $dst->get_mode('cb_showjoin');
			$net->cmd1(NOTICE => $dst, 'Part: '.$src->str($net).' '.$act->{msg});
		}
	},
	QUIT => sub {
		my($net,$act) = @_;
		my $nick = $act->{dst};
		my @out;
		for my $chan ($nick->all_chans()) {
			next unless $chan->is_on($net) && $chan->get_mode('cb_showjoin');
			push @out, $net->cmd1(NOTICE => $chan, 'Quit: '.$nick->str($net).' '.$act->{msg});
		}
		@out;
	},
	NICK => sub {
		my($net,$act) = @_;
		my $nick = $act->{dst};
		my @out;
		my $msg = 'Nick: '.$act->{from}->{$$net}.' changed to '.
			$act->{to}->{$$net}.'!'.$nick->info('ident').'@'.$nick->info('vhost');
		for my $chan ($nick->all_chans()) {
			next unless $chan->is_on($net) && $chan->get_mode('cb_showjoin');
			push @out, $net->cmd1(NOTICE => $chan, $msg);
		}
		@out;
	},
	MSG => sub {
		my($net,$act) = @_;
		my $type = $act->{msgtype};
		return () unless $type eq 'PRIVMSG' || $type eq 'NOTICE';
		my $src = $act->{src};
		my $dst = $act->{dst};
		my $msg = $act->{msg};
		return () unless ref $src && $src->isa('Nick');
		return () unless ref $dst && ($dst->isa('Nick') || $dst->isa('Channel'));
		my $dstr = $dst->str($net);
		if ($dst->isa('Channel') && $dst->get_mode('cb_direct')) {
			return "$type $dstr :$msg";
		} else {
			my $nick = $src->str($net);
			$nick = $src->homenick . '/' . $src->homenet->name if !defined $nick;
			if ($msg =~ /^\001ACTION (.*?)\001?$/) {
				return "$type $dstr :* $nick $1";
			} else {
				return "$type $dstr :<$nick> $msg";
			}
		}
	},
	KICK => sub {
		my($net,$act) = @_;
		my $nick = $act->{kickee};
		return () unless $nick->homenet() eq $net;
		my $src = $act->{src};
		my $chan = $act->{dst};
		$src = ref $src && $src->isa('Nick') ? '<'.$src->str($net).'>' : '[?]';
		my $cn = $chan->str($net);
		my $nn = $nick->str($net);
		my $evt = [ 5, "KICK $cn $nn :$src $act->{msg}", 'KICK', $cn, $nick ];
		weaken($evt->[4]);
		$net->add_halfout($evt);
		();
	},
	MODE => sub {
		my ($net,$act) = @_;
		my $chan = $act->{dst};
		my @mm = @{$act->{mode}};
		my @ma = @{$act->{args}};
		my @md = @{$act->{dirs}};
		my $i = 0;
		while ($i < @mm) {
			if (Modes::mtype($mm[$i]) eq 'n' && $ma[$i]->homenet != $net) {
				splice @mm, $i, 1;
				splice @ma, $i, 1;
				splice @md, $i, 1;
			} elsif ($mm[$i] eq 'cb_modesync' && $md[$i] eq '+') {
				my @modes = Modes::to_multi($net, Modes::delta(undef, $chan), $capabs[$$net]{MODES});
				return map $net->cmd1(MODE => $chan, @$_), @modes;
			} else {
				$i++;
			}
		}
		return () unless $chan->get_mode('cb_modesync');

		my @modes = Modes::to_multi($net, \@mm, \@ma, \@md, $capabs[$$net]{MODES});
		map $net->cmd1(MODE => $chan, @$_), @modes;
	},
	TOPIC => sub {
		my ($net,$act) = @_;
		$net->cmd1(TOPIC => $act->{dst}, $act->{topic});
	},
	PING => sub {
		my ($net,$act) = @_;
		# slip pings onto the head of the send queue
		unshift @{$sendq[$$net]}, "PING :poing";
		return ();
	},
	IDENTIFY => sub {
		my ($net,$act) = @_;
		my $m = $act->{method} || $net->param('authtype');
		unless ($m) {
			$m = '';
			$m = 'ns' if $net->param('nspass');
			$m = 'Q' if $net->param('qauth');
		}
		if ($m eq 'Q') {
			my $qpass = $net->param('qauth') || '';
			Log::err_in($net, "Bad qauth syntax $qpass") unless $qpass && $qpass =~ /^\s*\S+\s+\S+\s*$/;
			'PRIVMSG Q@CServe.quakenet.org :AUTH '.$qpass;
		} elsif ($m eq 'ns') {
			my $pass = $net->param('nspass') || '';
			Log::err_in($net, "Bad nickserv password $pass") unless $pass;
			"PRIVMSG NickServ :IDENTIFY $pass";
		} elsif ($m eq 'nsalias') {
			my $pass = $net->param('nspass') || '';
			Log::err_in($net, "Bad nickserv password $pass") unless $pass;
			"NICKSERV :IDENTIFY $pass";
		} elsif ($m ne '') {
			Log::warn_in($net, "Unknown identify method $m");
			();
		}
	},
	WHOIS => sub {
		my($net,$act) = @_;
		Event::append(&Interface::whois_reply($act->{src}, $act->{dst}, 0, 0));
		();
	},
);

sub cb_cmd {
	my($net,$src,$msg) = @_;
# TODO make generic, more commands
	if ($msg =~ /^names (#\S*)/i) {
		my $chan = $net->chan($1);
		if ($chan) {
			my @nicks = grep { $_->homenet != $net } $chan->all_nicks;
			my @table = map [ Modes::chan_pfx($chan, $_) . $_->str($net) ], @nicks;
			Interface::msgtable($src, \@table, cols => 6, pfx => $1.' ');
		} else {
			Janus::jmsg($src, 'Not on that channel');
		}
	} else {
		Janus::jmsg($src, 'Unknown command');
	}
	return ();
}

sub pm_not {
	my $net = shift;
	my $src = $net->item($_[0]) or return ();
	my $dst = $net->item($_[2]) or return ();
	return () unless $src->isa('Nick');
	if ($dst == $Interface::janus) {
		# PM to the bot
		my $msg = $_[3];
		return if $msg =~ /^\001/; # ignore CTCPs
		return cb_cmd($net, $src, $msg) if $msg =~ s/^!//;
		if ($msg =~ s/^(\S+)\s//) {
			$dst = $net->item($1);
			if (ref $dst && $dst->isa('Nick') && $dst->homenet() ne $net) {
				return () if $dst == $Interface::janus;
				return +{
					type => 'MSG',
					src => $src,
					dst => $dst,
					msgtype => $_[1],
					msg => $msg,
				};
			}
		}
		if ($_[1] eq 'PRIVMSG') {
			$net->send("NOTICE $_[0] :Error: user not found. To message a user, prefix your message with their nick");
		} elsif ($_[1] eq 'NOTICE') {
			if (lc $_[0] eq 'nickserv') {
				if ($_[3] =~ /(registered|protected|identify)/i && $_[3] !~ / not /i) {
					return +{
						type => 'IDENTIFY',
						dst => $net,
						method => 'ns',
					};
				} elsif ($_[3] =~ /wrong\spassword/ ) {
					Log::err_in($net, "Wrong password mentioned in the config file.");
				}
			} elsif (uc $_[0] eq 'Q' && $_[3] =~ /registered/i ) {
				return +{
					type => 'IDENTIFY',
					dst => $net,
					method => 'Q',
				};
			}
		}
		return ();
	} elsif ($dst->isa('Channel')) {
		return +{
			type => 'MSG',
			src => $src,
			msgtype => $_[1],
			dst => $dst,
			msg => $_[3],
		};
	} else {
		# server msg, etc. Ignore.
		();
	}
}

sub kicked {
	my($net, $cname, $msg,$knick) = @_;
	my $chan = $net->chan($cname) or return ();
	my @out;
	for my $nick ($chan->all_nicks()) {
		next unless $nick->homenet() eq $net;
		push @out, +{
			type => 'PART',
			src => $nick,
			dst => $chan,
			msg => 'Janus relay bot kicked by '.$knick.': '.$msg,
		};
		my @chans = $nick->all_chans();
		if (!@chans || (@chans == 1 && lc $chans[0]->str($net) eq lc $cname)) {
			push @out, +{
				type => 'QUIT',
				dst => $nick,
				msg => 'Janus relay bot cannot see this nick',
			};
		}
	}
	my $rejoin = Setting::get(kick_rejoin => $net);
	if ($rejoin) {
		$net->add_halfout([ 10, "JOIN $cname", 'JOIN', $cname ]);
	} else {
		push @out, +{
			type => 'DELINK',
			cause => 'unlink',
			dst => $chan,
			net => $net,
		};
	}
	@out;
}

%fromirc = (
	PRIVMSG => \&pm_not,
	NOTICE => \&pm_not,
	JOIN => sub {
		my $net = shift;
		if (lc $_[0] eq lc $self[$$net]) {
			my $curr = $half_out[$$net][0];
			if ($curr && $curr->[2] eq 'JOIN' && lc $curr->[3] eq lc $_[2]) {
				$net->add_halfout([ 30, "WHO $_[2]", 'WHO/C', $_[2], {} ]);
				$net->shift_halfout();
			} else {
				my $chan = $net->chan($_[2]);
				$net->send("PART $_[2] :Channel not voluntarily joined") unless $chan;
			}
			return ();
		}
		my $src = $net->mynick($_[0]) or return ();
		return +{
			type => 'JOIN',
			src => $src,
			dst => $net->chan($_[2], 1),
		};
	},
	NICK => sub {
		my $net = shift;
		if (lc $_[0] eq lc $self[$$net]) {
			$self[$$net] = $_[2];
			return ();
		}
		my $nick = $net->mynick($_[0]) or return ();
		my $replace = $net->item($_[2]);
		$replace = undef if $replace && $replace == $nick;
		my @out;
		if ($replace && $replace->homenet() eq $net) {
			push @out, +{
				type => 'QUIT',
				dst => $replace,
				msg => 'De-sync collision from nick change',
			};
		} elsif ($replace) {
			push @out, +{
				type => 'RECONNECT',
				dst => $replace,
				net => $net,
				killed => 0,
				altnick => 1,
				sendto => [ $net ],
			};
		}
		push @out, +{
			type => 'NICK',
			src => $nick,
			dst => $nick,
			nick => $_[2],
		};
		@out;
	},
	PART => sub {
		my $net = shift;
		my $chan = $net->chan($_[2]) or return ();
		if (lc $_[0] eq lc $self[$$net]) {
			if (grep $_ == $chan, $Interface::janus->all_chans) {
				# SAPART == same as kick
				return $net->kicked($_[2], $_[3],$_[1]);
			} else {
				return ();
			}
		}
		my $nick = $net->mynick($_[0]) or return ();
		my @out = +{
			type => 'PART',
			src => $nick,
			dst => $chan,
			msg => $_[3],
		};
		for my $i (0..$#{$half_out[$$net]}) {
			my $curr = $half_out[$$net][$i];
			next unless $curr->[2] eq 'KICK' && lc $curr->[3] eq lc $_[2];
			next unless $curr->[4] && $curr->[4] == $nick;
			if ($i) {
				splice @{$half_out[$$net]}, $i, 1;
			} else {
				$net->shift_halfout();
			}
			shift @out;
			last;
		}
		my @chans = $nick->all_chans();
		if (!@chans || (@chans == 1 && lc $chans[0]->str($net) eq lc $_[2])) {
			push @out, +{
				type => 'QUIT',
				dst => $nick,
				msg => 'Part: '.($_[3] || ''),
			};
		}
		@out;
	},
	KICK => sub {
		my $net = shift;
		my $src = $net->item($_[0]);
		my $chan = $net->chan($_[2]) or return ();
		my $victim = $net->nick($_[3]) or return ();
		if ($victim == $Interface::janus) {
			if (grep $_ == $chan, $victim->all_chans) {
				return $net->kicked($_[2], $_[4],$_[0]);
			} else {
				return ();
			}
		}
		my @out;
		push @out, +{
			type => 'KICK',
			src => $src,
			dst => $chan,
			kickee => $victim,
			msg => $_[4],
		};
		for my $i (0..$#{$half_out[$$net]}) {
			my $curr = $half_out[$$net][$i];
			next unless $curr->[2] eq 'KICK' && lc $curr->[3] eq lc $_[2];
			next unless $curr->[4] && $curr->[4] == $victim;
			if ($i) {
				splice @{$half_out[$$net]}, $i, 1;
			} else {
				$net->shift_halfout();
			}
			shift @out;
			last;
		}
		my @chans = $victim->all_chans();
		if (!@chans || (@chans == 1 && lc $chans[0]->str($net) eq lc $_[2])) {
			push @out, +{
				type => 'QUIT',
				dst => $victim,
				msg => 'Kicked: '.($_[3] || ''),
			};
		}
		@out;
	},
	QUIT => sub {
		my $net = shift;
		my $src = $net->mynick($_[0]) or return ();
		return +{
			type => 'QUIT',
			dst => $src,
			msg => $_[2],
		};
	},
	PING => sub {
		my $net = shift;
		$net->send("PONG :$_[2]");
		();
	},
	PONG => \&ignore,
	MODE => sub {
		my $net = shift;
		if (lc $_[0] eq lc $self[$$net]) {
			# confirmation of self-sourced mode change
		} elsif ($_[2] =~ /^#/) {
			my $nick = $net->item($_[0]) or return ();
			my $chan = $net->chan($_[2]) or return ();
			return () unless $chan->get_mode('cb_modesync');
			my($modes,$args,$dirs) = Modes::from_irc($net, $chan, @_[3 .. $#_]);
			my $i = 0;
			while ($i < @$modes) {
				if (Modes::mtype($modes->[$i]) eq 'n' && $args->[$i]->homenet != $net) {
					splice @$modes, $i, 1;
					splice @$args, $i, 1;
					splice @$dirs, $i, 1;
				} else {
					$i++;
				}
			}

			return +{
				type => 'MODE',
				src => $nick,
				dst => $chan,
				mode => $modes,
				args => $args,
				dirs => $dirs,
			};
		}
		();
	},

	ERROR => sub {
		my $net = shift;
		return +{
			type => 'NETSPLIT',
			net => $net,
			msg => $_[-1],
		};
	},
	# misc
	'001' => sub {
		my $net = shift;
		my $curr = $half_out[$$net][0];
		unless ($curr && $curr->[2] eq 'USER') {
			Log::warn_in($net, 'Unexpected 001 numeric');
		}
		if ($net->cparam('linktype') eq 'tls' && !$capabs[$$net]{' TLS'}) {
			return {
				type => 'NETSPLIT',
				net => $net,
				msg => 'STARTTLS failed',
			};
		}
		return +{
			type => 'NETLINK',
			net => $net,
		}, +{
			type => 'LINKED',
			net => $net,
		}, +{
			type => 'IDENTIFY',
			dst => $net,
		};
	},
	'002' => \&ignore,
	'003' => \&ignore,
	'004' => sub {
		my $net = shift;
		my @keys = qw/server ircd umodes cmodes cmodes2/;
		for my $i (3..$#_) {
			$capabs[$$net]{' '.$keys[$i-3]} = $_[$i];
		}
		my $curr = $half_out[$$net][0];
		unless ($curr && $curr->[2] eq 'USER') {
			Log::warn_in($net, 'Unexpected 004 numeric');
			$net->process_capabs();
		}
		();
	},
	'005' => sub {
		my $net = shift;
		for (@_[3..($#_-1)]) {
			if (/^([^ =]+)(?:=(.*))?$/) {
				$capabs[$$net]{$1} = $2;
			} else {
				Log::warn_in($net, "Invalid 005 line: $_");
			}
		}
		my $curr = $half_out[$$net][0];
		unless ($curr && $curr->[2] eq 'USER') {
			Log::warn_in($net, 'Unexpected 005 numeric');
			$net->process_capabs();
		}
		();
	},
	'042' => \&ignore,
	# intro (/lusers etc)
	250 => \&ignore,
	251 => \&ignore,
	252 => \&ignore,
	253 => \&ignore,
	254 => \&ignore,
	255 => \&ignore,
	265 => \&ignore,
	266 => \&ignore,
	# MOTD
	375 => \&ignore,
	372 => \&ignore,
	376 => sub { # end of MOTD
		my $net = shift;
		my $curr = $half_out[$$net][0];
		if ($curr && $curr->[2] eq 'USER') {
			$net->process_capabs();
			$net->shift_halfout();
		}
		();
	},
	422 => sub { # MOTD missing
		my $net = shift;
		my $curr = $half_out[$$net][0];
		if ($curr && $curr->[2] eq 'USER') {
			$net->process_capabs();
			$net->shift_halfout();
		}
		();
	},

	301 => \&ignore, # away
	331 => \&ignore, # no topic
	332 => sub {
		my $net = shift;
		$half_in[$$net] = [ 'TOPIC', $_[3], $_[-1] ];
		();
	},
	333 => sub {
		my $net = shift;
		my $h = $half_in[$$net];
		unless ($h && $h->[0] eq 'TOPIC' && $h->[1] eq $_[3]) {
			Log::warn_in($net, 'Malformed 333 numeric (no matching 332 found)');
			return ();
		}
		$half_in[$$net] = undef;
		my $chan = $net->chan($_[3]) or return ();
		return () unless $chan->get_mode('cb_topicsync');
		return {
			type => 'TOPIC',
			topic => $h->[2],
			src => $net,
			dst => $chan,
			topicts => $_[5],
			topicset => $_[4],
		};
	},

	TOPIC => sub {
		my $net = shift;
		my $src = $net->item($_[0]) or return ();
		my $chan = $net->chan($_[2]) or return ();
		return () if $src == $Interface::janus;
		return () unless $chan->get_mode('cb_topicsync');
		return {
			type => 'TOPIC',
			topic => $_[-1],
			src => $src,
			dst => $chan,
			topicts => $Janus::time,
			topicset => $_[0],
		};
	},

	352 => sub {
		my $net = shift;
#		:server 352 j #test ident host their.server nick Hr*@ :0 Gecos
		my $curr = $half_out[$$net][0];
		my $chan;
		if ($curr && $curr->[2] eq 'WHO/C') {
			unless (lc $curr->[3] eq lc $_[3]) {
				Log::warn_in($net, 'Unexpected WHO reply, expecting '.$curr->[3].', got '.$_[3]);
				return ();
			}
			delete $curr->[4]{$_[7]};
			$chan = $net->chan($_[3]);
		} elsif ($curr && $curr->[2] eq 'WHO/N') {
			unless (lc $curr->[3] eq lc $_[7]) {
				Log::warn_in($net, 'Unexpected WHO reply, expecting '.$curr->[3].', got '.$_[7]);
				return ();
			}
			if (@$curr == 6) {
				$chan = $net->chan($curr->[4]);
				$_[8] = $curr->[5];
			}
		} else {
			Log::warn_in($net, 'Unexpected WHO reply');
			return ();
		}
		return () if lc $_[7] eq lc $self[$$net];
		my $gecos = $_[-1];
		$gecos =~ s/^\d+\s//; # remove server hop count
		my @out = $net->cli_hostintro($_[7], $_[4], $_[5], $gecos);
		my %mode;
		$mode{op} = 1 if $_[8] =~ /[~&\@]/;
		$mode{halfop} = 1 if $_[8] =~ /\%/;
		$mode{voice} = 1 if $_[8] =~ /\+/;
		push @out, +{
			type => 'JOIN',
			src => $net->mynick($_[7]),
			dst => $chan,
			mode => \%mode,
		} if $chan;
		@out;
	},
	315 => sub {
		my $net = shift;
		my $curr = $half_out[$$net][0];
		if ($curr && $curr->[2] =~ /^WHO/ && lc $curr->[3] eq lc $_[3]) {
			if ($curr->[2] eq 'WHO/C' && %{$curr->[4]}) {
				Log::debug_in($net, "Incomplete channel /WHO reply for $_[3], querying manually");
				for my $k (keys %{$curr->[4]}) {
					$net->add_halfout([ 10, "WHO $k", 'WHO/N', $k, $_[3], $curr->[4]{$k} ]);
				}
			}
			$net->shift_halfout();
		} else {
			Log::warn_in($net, 'Unexpected end-of-who ', @_[3..$#_]);
		}
		();
	},
	353 => sub {
		my $net = shift;
		# :server 353 jmirror = #channel :nick @nick
		for my $curr (@{$half_out[$$net]}) {
			if ($curr && $curr->[2] eq 'WHO/C' && lc $curr->[3] eq lc $_[4]) {
				/^([-,.`*?!^~&\$\@\%+=]*)(.*)/ and $curr->[4]{$2} = $1 for split / /, $_[-1];
			}
		}
		();
	},
	366 => \&ignore, # end of /NAMES
	400 => \&ignore, # no suck Nick
	433 => sub { # nick in use, try another
		my $net = shift;
		my $tried = $_[3];
		my $n = '';
		$n = ($1 || 0) + 1 if $tried =~ s/_(\d*)$//;
		$tried .= '_'.$n;
		$net->send("NICK $tried");
		$self[$$net] = $tried;
		();
	},
	471 => \&delink_cancel_join,
	473 => \&delink_cancel_join,
	474 => \&delink_cancel_join,
	475 => \&delink_cancel_join,
	495 => \&delink_cancel_join,
	520 => \&delink_cancel_join,
	482 => sub { # need channel ops
		my $net = shift;
		my $chan = $net->chan($_[3]) or return ();
		return +{
			type => 'MSG',
			src => $net,
			dst => $chan,
			msgtype => 'NOTICE',
			prefix => '@',
			msg => 'Relay bot not opped on network '.$net->name,
		};
	},
	477 => sub { # Need to register.
		my $net = shift;
		my @out;
		my $curr = $half_out[$$net][0];
		if ($curr && $curr->[2] eq 'JOIN') {
			$net->shift_halfout();
			my $cname = $curr->[3];
			my $chan = $net->chan($cname);
			if ($chan) {
				push @out, +{
					type => 'DELINK',
					cause => 'unlink',
					dst => $chan,
					net => $net,
				}
			}
		}
		push @out, +{
			type => 'IDENTIFY',
			dst => $net,
		};
		@out;
	},
	670 => sub {
		my $net = shift;
		my $curr = $half_out[$$net][0];
		if ($curr && $curr->[2] eq 'TLS') {
			my($ssl_key, $ssl_cert, $ssl_ca) = Conffile::find_ssl_keys($net->name);
			Connection::starttls($net, $ssl_key, $ssl_cert, $ssl_ca);
			$net->shift_halfout();
			$capabs[$$net]{' TLS'}++;
		} else {
			Log::warn_in($net, 'Unexpected 670 numeric');
		}
		();
	},
);

Event::hook_add(
	INFO => 'Network:1' => sub {
		my($dst, $net, $asker) = @_;
		return unless $net->isa(__PACKAGE__);
		Janus::jmsg($dst, 'Bot nick: '.$self[$$net]);
		Janus::jmsg($dst, join '', 'Server info:', sort map {
			defined $capabs[$$net]{$_} ? "$_=$capabs[$$net]{$_}" : $_
		} grep /^ /, keys %{$capabs[$$net]});
		Janus::jmsg($dst, join ' ','Server 005:', sort map {
			defined $capabs[$$net]{$_} ? "$_=$capabs[$$net]{$_}" : $_
		} grep !/ /, keys %{$capabs[$$net]});
	},
);

1;
