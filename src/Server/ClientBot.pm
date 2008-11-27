# Copyright (C) 2007-2008 Daniel De Graaf
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

our(@sendq, @self, @kicks, @lchan, @flood_bkt, @flood_ts);
&Persist::register_vars(qw(sendq self kicks lchan flood_bkt flood_ts));
# $kicks[$$net]{$lid$channel} = 1 for a rejoin enabled
# lchan = last channel we tried to join

our $awaken;

my %fromirc;
my %toirc;
sub _init {
	my $net = shift;
	$sendq[$$net] = [];
}

sub ignore { () }

sub unkick {
	my $e = shift;
	my($net, $nick, $chan) = @$e{qw(net nick chan)};
	return unless $net && $nick && $chan && $kicks[$$net]{$$nick.$chan->str($net)};
	&Event::insert_full(+{
		type => 'JOIN',
		src => $nick,
		dst => $chan,
	});
}

sub invisquit {
	my $e = shift;
	my $nick = $e->{nick} or return;
	return if $nick->all_chans;
	&Event::insert_full(+{
		type => 'QUIT',
		dst => $nick,
		msg => 'Janus relay bot cannot see this nick',
	});
}

sub intro {
	my($net,$param) = @_;
	$net->SUPER::intro($param);
	$net->send(
		'USER mirror gamma * :Janus IRC Client',
		"NICK $param->{nick}",
	);
	$self[$$net] = $param->{nick};
	$flood_bkt[$$net] = $param->{tbf_max} || 20;
	$flood_ts[$$net] = $Janus::time;
}

my %cmode2txt = (qw/
	q n_op
	a n_op
	o n_op
	h n_halfop
	v n_voice

	b l_ban
	l s_limit
	i r_invite
	m r_moderated
	n r_mustjoin
	p t1_chanhide
	s t2_chanhide
	t r_topic
/);

my %txt2cmode;
$txt2cmode{$cmode2txt{$_}} = $_ for keys %cmode2txt;
$txt2cmode{n_op} = 'o';

sub cmode2txt {
	$cmode2txt{$_[1]};
}
sub txt2cmode {
	$txt2cmode{$_[1]};
}

sub cli_hostintro {
	my($net, $nname, $ident, $host, $gecos) = @_;
	my @out;
	return if lc $nname eq lc $self[$$net];
	my $nick = $net->item($nname);

	unless ($nick && $nick->homenet == $net) {
		my $ts = $Janus::time;
		if ($nick) {
			# someone already exists, but remote. They get booted off their current nick
			$ts = $nick->ts - 1;
		}
		$nick = Nick->new(
			net => $net,
			ts => $ts,
			nick => $nname,
			info => {
				host => $host,
				vhost => $host,
				ident => $ident,
				name => ($gecos || 'MirrorServ Client'),
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
		&Event::schedule($evt);

		my($ok, @acts) = $net->nick_collide($nname, $nick);
		warn 'Invalid clientbot collision' unless $ok;
		push @out, @acts, +{
			type => 'NEWNICK',
			dst => $nick,
		};
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
	&Log::netin(@_);
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
		&Log::warn_in($net, "Unknown command in line $line");
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
		return $net->cparam('linkname') if $itm eq $net;
		return $itm->jname();
	} else {
		&Log::warn_in($net,"Unknown item $itm");
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

sub dump_sendq {
	my $net = shift;
	local $_;
	my $tokens = $flood_bkt[$$net];
	my $rate = $net->param('tbf_rate') || 3;
	my $max = $net->param('tbf_max') || 20;
	$tokens += ($Janus::time - $flood_ts[$$net])*$rate;
	$tokens = $max if $tokens > $max;
	my $q = '';
	while ($tokens && @{$sendq[$$net]}) {
		my $line = shift @{$sendq[$$net]};
		$q .= $line . "\r\n";
		&Log::netout($net, $line);
		$tokens--;
	}
	$flood_ts[$$net] = $Janus::time;
	$flood_bkt[$$net] = $tokens;
	if (@{$sendq[$$net]} && !$awaken) {
		$awaken = {
			delay => 1,
			code => sub { $awaken = undef; },
		};
		&Event::schedule($awaken);
	}
	$q;
}

sub request_newnick {
	my($net, $nick, $reqnick, $tag) = @_;
# uncomment to force tags
#	$tag = 1;
	$reqnick = $self[$$net] if $nick == $Interface::janus;
	&Server::BaseNick::request_nick($net, $nick, $reqnick, $tag);
}

sub request_cnick {
	my($net, $nick, $reqnick, $tag) = @_;
	$reqnick = $self[$$net] if $nick == $Interface::janus;
	&Server::BaseNick::request_cnick($net, $nick, $reqnick, $tag);
}

sub nicklen { 40 }

%toirc = (
	JOIN => sub {
		my($net,$act) = @_;
		my $src = $act->{src};
		my $dst = $act->{dst};
		return () unless $src == $Interface::janus;
		my $chan = $dst->str($net);
		$lchan[$$net] = $chan;
		"JOIN $chan";
	},
	PART => sub {
		my($net,$act) = @_;
		my $src = $act->{src};
		my $dst = $act->{dst};
		return () unless $src == $Interface::janus;
		my $chan = $dst->str($net);
		"PART $chan :$act->{msg}";
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
		if ($dst->isa('Channel') && $dst->get_mode('cbdirect')) {
			return "$type $dstr :$msg";
		} else {
			$src = $src->str($net);
			if ($msg =~ /^\001ACTION (.*?)\001?$/) {
				return "$type $dstr :* $src $1";
			} else {
				return "$type $dstr :<$src> $msg";
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
		my $evt = {
			delay => 15,
			net => $net,
			nick => $nick,
			chan => $chan,
			code => \&unkick,
		};
		weaken($evt->{net});
		weaken($evt->{nick});
		weaken($evt->{chan});
		&Event::schedule($evt);
		$kicks[$$net]{$$nick.$cn} = 1;
		"KICK $cn $nn :$src $act->{msg}";
	},
	MODE => sub {
		my ($net,$act) = @_;
		my @mm = @{$act->{mode}};
		my @ma = @{$act->{args}};
		my @md = @{$act->{dirs}};
		my $i = 0;
		while ($i < @mm) {
			if ($Modes::mtype{$mm[$i]} eq 'n' && $ma[$i]->homenet != $net) {
				splice @mm, $i, 1;
				splice @ma, $i, 1;
				splice @md, $i, 1;
			} else {
				$i++;
			}
		}

		my @modes = &Modes::to_multi($net, \@mm, \@ma, \@md, 12);
		map $net->cmd1(MODE => $act->{dst}, @$_), @modes;
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
			&Log::err_in($net, "Bad qauth syntax $qpass") unless $qpass && $qpass =~ /^\s*\S+\s+\S+\s*$/;
			'PRIVMSG Q@CServe.quakenet.org :AUTH '.$qpass;
		} elsif ($m eq 'ns') {
			my $pass = $net->param('nspass') || '';
			&Log::err_in($net, "Bad nickserv password $pass") unless $pass;
			"PRIVMSG NickServ :IDENTIFY $pass";
		} elsif ($m eq 'nsalias') {
			my $pass = $net->param('nspass') || '';
			&Log::err_in($net, "Bad nickserv password $pass") unless $pass;
			"NICKSERV :IDENTIFY $pass";
		} elsif ($m ne '') {
			&Log::warn_in($net, "Unknown identify method $m");
			();
		}
	},
	WHOIS => sub {
		my($net,$act) = @_;
		&Event::append(&Interface::whois_reply($act->{src}, $act->{dst}, 0, 0));
		();
	},
);

sub pm_not {
	my $net = shift;
	my $src = $net->item($_[0]) or return ();
	return () unless $src->isa('Nick');
	if (lc $_[2] eq lc $self[$$net]) {
		# PM to the bot
		my $msg = $_[3];
		return if $msg =~ /^\001/; # ignore CTCPs
		if ($msg =~ s/^(\S+)\s//) {
			my $dst = $net->item($1);
			if (ref $dst && $dst->isa('Nick') && $dst->homenet() ne $net) {
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
					&Log::err_in($net, "Wrong password mentioned in the config file.");
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
	}
	my $dst = $net->item($_[2]) or return ();
	return () unless $dst->isa('Channel');
	return +{
		type => 'MSG',
		src => $src,
		msgtype => $_[1],
		dst => $dst,
		msg => $_[3],
	};
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
	# try to rejoin - TODO enqueue the channel and delink it if this doesn't succeed in a little bit
	$net->send("JOIN $cname");
	@out;
}

%fromirc = (
	PRIVMSG => \&pm_not,
	NOTICE => \&pm_not,
	JOIN => sub {
		my $net = shift;
		if (lc $_[0] eq lc $self[$$net]) {
			$lchan[$$net] = undef if $_[2] eq $lchan[$$net];
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
		my $nick = $net->mynick($_[0]) or return ();
		my $replace = (lc $_[0] eq lc $_[2]) ? undef : $net->item($_[2]);
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
		delete $kicks[$$net]{$$nick.$_[2]};
		my @out = +{
			type => 'PART',
			src => $nick,
			dst => $chan,
			msg => $_[3],
		};
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
		my $src = $net->nick($_[0]);
		my $chan = $net->chan($_[2]) or return ();
		my $victim = $net->nick($_[3]) or return ();
		if ($victim == $Interface::janus) {
			if (grep $_ == $chan, $victim->all_chans) {
				return $net->kicked($_[2], $_[4],$_[0]);
			} else {
				return ();
			}
		}
		delete $kicks[$$net]{$$victim.$_[2]};
		my @out;
		push @out, +{
			type => 'KICK',
			src => $src,
			dst => $chan,
			kickee => $victim,
			msg => $_[4],
		};
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
			my($modes,$args,$dirs) = &Modes::from_irc($net, $chan, @_[3 .. $#_]);
			my $i = 0;
			while ($i < @$modes) {
				if ($Modes::mtype{$modes->[$i]} eq 'n' && $args->[$i]->homenet != $net) {
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
	'004' => \&ignore,
	'005' => \&ignore,
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
	372 => \&ignore,
	375 => \&ignore,
	376 => \&ignore,
	422 => \&ignore, # MOTD missing

	301 => \&ignore, # away
	331 => \&ignore, # no topic
	332 => sub {
		my $net = shift;
		my $chan = $net->chan($_[3]) or return ();
		return {
			type => 'TOPIC',
			topic => $_[-1],
			dst => $chan,
			topicts => $Janus::time,
			topicset => 'Client',
		};
	},
	333 => \&ignore, # 333 J #foo setter ts

	TOPIC => sub {
		my $net = shift;
		return if lc $_[0] eq lc $self[$$net];
		my $chan = $net->chan($_[2]) or return ();
		return {
			type => 'TOPIC',
			topic => $_[-1],
			dst => $chan,
			topicts => $Janus::time,
			topicset => $_[0],
		};
	},

	315 => \&ignore, # end of /WHO
	352 => sub {
		my $net = shift;
#		:irc2.smashthestack.org 352 jmirror #test me admin.daniel irc2.smashthestack.org daniel Hr* :0 Why don't you ask me?
		my $chan = $net->chan($_[3]) or return ();
		my $n = $_[-1];
		$n =~ s/^\d+\s+//;
		return () if lc $_[7] eq lc $self[$$net];
		my @out = $net->cli_hostintro($_[7], $_[4], $_[5], $n);
		my %mode;
		$mode{op} = 1 if $_[8] =~ /~/;
		$mode{op} = 1 if $_[8] =~ /&/;
		$mode{op} = 1 if $_[8] =~ /\@/;
		$mode{halfop} = 1 if $_[8] =~ /\%/;
		$mode{voice} = 1 if $_[8] =~ /\+/;
		push @out, +{
			type => 'JOIN',
			src => $net->mynick($_[7]),
			dst => $chan,
			mode => \%mode,
		};
		@out;
	},
	353 => \&ignore, # /NAMES list
	366 => sub { # end of /NAMES
		my $net = shift;
		$net->send("WHO $_[3]");
		();
	},
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
	471 => sub { # +l User list if full.
		my $net = shift;
		my $chan = $net->chan($_[3]) or return ();
		return +{
			type => 'DELINK',
			cause => 'unlink',
			dst => $chan,
			net => $net,
		};
	},
	473 => sub { # +i invited only.
		my $net = shift;
		my $chan = $net->chan($_[3]) or return ();
		return +{
			type => 'DELINK',
			cause => 'unlink',
			dst => $chan,
			net => $net,
		};
	},
	474 => sub { # +b we are banned.
		my $net = shift;
		my $chan = $net->chan($_[3]) or return ();
		return +{
			type => 'DELINK',
			cause => 'unlink',
			dst => $chan,
			net => $net,
		};
	},
	475 => sub { # +k needs key.
		my $net = shift;
		my $chan = $net->chan($_[3]) or return ();
		return +{
			type => 'DELINK',
			cause => 'unlink',
			dst => $chan,
			net => $net,
		};
	},
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
		my $cname = $lchan[$$net] || "requested channel";
		my @out;
		my $chan = $net->chan($cname);
		if ($chan) {
			push @out, +{
				type => 'DELINK',
				cause => 'unlink',
				dst => $chan,
				net => $net,
			}
		}
		push @out, +{
			type => 'IDENTIFY',
			dst => $net,
		};
		@out;
	},
	520 => sub {
		my $net = shift;
		$_[3] =~ /(#\S+)/ or return ();
		my $chan = $net->chan($1) or return ();
		return +{
			type => 'DELINK',
			cause => 'unlink',
			dst => $chan,
			net => $net,
		};
	}
);

1;
