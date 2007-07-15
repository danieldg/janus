# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Inspircd_1105;
BEGIN { &Janus::load('LocalNetwork'); }
use Persist;
use Object::InsideOut 'LocalNetwork';
use strict;
use warnings;
&Janus::load('Nick');

__PERSIST__
persist @sendq     :Field;

persist @meta      :Field; # key => sub{} for METADATA command
persist @fromirc   :Field; # command => sub{} for IRC commands
persist @act_hooks :Field; # type => module => sub{} for Janus Action => output (m

persist @modules   :Field; # {module} => definition - List of active modules
persist @state     :Field; # state data
__CODE__

sub _init :Init {
	my $net = shift;
	$sendq[$$net] = [];
	$net->module_add('CORE');
}

sub ignore { () }

my %moddef;
sub module_add {
	my($net,$name) = @_;
	my $mod = $moddef{$name} or return;
	return if $modules[$$net]{$name};
	$modules[$$net]{$name} = $mod;
	if ($mod->{cmode}) {
		for my $cm (keys %{$mod->{cmode}}) {
			my $txt = $mod->{cmode}{$cm};
			warn "Overriding mode $cm" if $state[$$net]{cmode2txt}{$cm} || $state[$$net]{txt2cmode}{$txt};
			$state[$$net]{cmode2txt}{$cm} = $txt;
			$state[$$net]{txt2cmode}{$txt} = $cm;
		}
	}
	if ($mod->{umode}) {
		for my $um (keys %{$mod->{umode}}) {
			my $txt = $mod->{umode}{$um};
			warn "Overriding mode $um" if $state[$$net]{umode2txt}{$um} || $state[$$net]{txt2umode}{$txt};
			$state[$$net]{umode2txt}{$um} = $txt;
			$state[$$net]{txt2umode}{$txt} = $um;
		}
	}
	if ($mod->{cmds}) {
		for my $cmd (keys %{$mod->{cmds}}) {
			warn "Overriding command $cmd" if $fromirc[$$net]{$cmd};
			$fromirc[$$net]{$cmd} = $mod->{cmds}{$cmd};
		}
	}
	if ($mod->{acts}) {
		for my $t (keys %{$mod->{acts}}) {
			$act_hooks[$$net]{$t}{$name} = $mod->{acts}{$t};
		}
	}
	if ($mod->{metadata}) {
		for my $i (keys %{$mod->{metadata}}) {
			warn "Overriding metadata $i" if $meta[$$net]{$i};
			$meta[$$net]{$i} = $mod->{acts}{$i};
		}
	}
}

sub cmode2txt {
	my($net,$cm) = @_;
	$state[$$net]{cmode2txt}{$cm};
}

sub txt2cmode {
	my($net,$tm) = @_;
	$state[$$net]{txt2cmode}{$tm};
}

sub nicklen { 32 }

sub debug {
	print @_, "\n";
}

sub str {
	my $net = shift;
	$net->id().'.janus';
}

sub intro :Cumulative {
	my($net,$param) = @_;
	# do nothing until we receive a CAPAB message
}

# parse one line of input
sub parse {
	my ($net, $line) = @_;
	debug '     IN@'.$net->id().' '. $line;
	$net->pong();
	my ($txt, $msg) = split /\s+:/, $line, 2;
	my @args = split /\s+/, $txt;
	push @args, $msg if defined $msg;
	if ($args[0] !~ s/^://) {
		unshift @args, undef;
	}
	my $cmd = $args[1];
	unless ($state[$$net]{auth} || $cmd eq 'CAPAB' || $cmd eq 'SERVER') {
		$net->send('ERROR :Not authorized yet');
		return ();
	}
	return $net->nick_msg(@args) if $cmd =~ /^\d+$/;
	unless (exists $fromirc[$$net]{$cmd}) {
		debug "Unknown command '$cmd'";
		return ();
	}
	$fromirc[$$net]{$cmd}->($net,@args);
}

sub send {
	my $net = shift;
	for my $act (@_) {
		if (ref $act) {
			my $type = $act->{type};
			next unless $act_hooks[$$net]{$type};
			for my $hook (values %{$act_hooks[$$net]{$type}}) {
				push @{$sendq[$$net]}, $hook->($net,$act);
			}
		} else {
			push @{$sendq[$$net]}, $act;
		}
	}
}

sub dump_sendq {
	my $net = shift;
	local $_;
	my $q = join "\n", @{$sendq[$$net]}, '';
	$q =~ s/\n+/\r\n/g;
	$sendq[$$net] = [];
	debug '    OUT@'.$net->id().' '.$_ for split /\r\n/, $q;
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
		next unless exists $state[$$net]{txt2umode}{$m};
		$mode .= $state[$$net]{txt2umode}{$m};
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
	my $srv = $nick->homenet()->id() . '.janus';
	$srv = $net->cparam('linkname') if $srv eq 'janus.janus';

	my $ip = $nick->info('ip') || '0.0.0.0';
	$ip = '0.0.0.0' if $ip eq '*';
	my @out;
	push @out, $net->cmd2($srv, NICK => $nick->ts(), $nick, $nick->info('host'), $vhost, 
		$nick->info('ident'), $mode, $ip, $nick->info('name'));
	@out;
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

sub nick_msg {
	my $net = shift;
	my $src = $net->item($_[0]);
	my $msgtype = $_[1] + 0;
	my $msg = [ @_[3..$#_] ];
	my $dst = $net->nick($_[2]) or return ();
	return {
		type => 'MSG',
		src => $src,
		dst => $dst,
		msg => $msg,
		msgtype => $msgtype,
	};
}

sub nc_msg {
	my $net = shift;
	my $src = $net->item($_[0]);
	my $msgtype = 
		$_[1] eq 'PRIVMSG' ? 1 :
		$_[1] eq 'NOTICE' ? 2 :
		0;
	if ($_[2] =~ /^\$/) {
		# server broadcast message. No action; these are confined to source net
		return ();
	} elsif ($_[2] =~ /(.?)(#\S*)/) {
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

sub _parse_umode {
	my($net, $nick, $mode) = @_;
	my @mode;
	my $pm = '+';
	for (split //, $mode) {
		if (/[-+]/) {
			$pm = $_;
		} else {
			my $txt = $state[$$net]{umode2txt}{$_} or do {
				warn "Unknown umode '$_'";
				next;
			};
			push @mode, $pm.$txt;
		}
	}
	my @out;
	push @out, +{
		type => 'UMODE',
		dst => $nick,
		mode => \@mode,
	} if @mode;
	@out;
}

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
	$out .= $cmd;
	if (@_) {
		my $end = $net->_out(pop @_);
		$out .= ' '.$net->_out($_) for @_;
		$out .= ' :'.$end;
	}
	$out;
}

%moddef = (
'm_alias.so' => {
}, 'm_alltime.so' => {
	cmds => { ALLTIME => \&ignore, },
}, 'm_antibear.so' => {
}, 'm_antibottler.so' => {
}, 'm_auditorium.so' => {
	cmode => { u => 'r_auditorium' },
}, 'm_banexception.so' => {
	cmode => { e => 'l_except' },
}, 'm_banredirect.so' => {
}, 'm_blockamsg.so' => {
}, 'm_blockcaps.so' => {
}, 'm_blockcolor.so' => {
	cmode => { c => 'r_colorblock' },
}, 'm_botmode.so' => {
	umode => { B => 'bot' },
}, 'm_cban.so' => {
}, 'm_censor.so' => {
	cmode => { G => 'r_badword' },
	umode => { G => 'badword' },
}, 'm_cgiirc.so' => {
}, 'm_chancreate.so' => {
}, 'm_chanfilter.so' => {
	cmode => { g => 'l_badwords' },
}, 'm_chanprotect.so' => {
	cmode => { a => 'n_admin', q => 'n_owner' },
}, 'm_check.so' => {
}, 'm_chghost.so' => {
	cmds => { CHGHOST => sub {
		my $net = shift;
		my $dst = $net->mynick($_[2]) or return ();
		return +{
			type => 'NICKINFO',
			src => $net->item($_[0]),
			dst => $dst,
			item => 'host',
			value => $_[3],
		};
	} },
# TODO continue alphabetically on the module list
}, CORE => {
	cmode => {
		b => 'l_ban',
		h => 'n_halfop',
		i => 'r_invite',
		k => 'v_key',
		l => 's_limit',
		m => 'r_moderated',
		n => 'r_mustjoin',
		o => 'n_op',
		p => 'r_private',
		s => 'r_secret',
		t => 'r_topic',
		v => 'n_voice',
	},
	umode => {
		i => 'invisible',
		n => 'snomask',
		o => 'oper',
		s => 'globops', # technically, server notices
		w => 'wallops',
	},
  cmds => {
  	NICK => sub {
		my $net = shift;
		if (@_ < 10) {
			# TODO nick change
			return ();
		}
		my %nick = (
			net => $net,
			ts => $_[2],
			nick => $_[3],
			info => {
				host => $_[4],
				vhost => $_[5],
				ident => $_[6],
				ip => $_[8],
				name => $_[-1],
			},
		);
		my @m = split //, $_[7];
		warn unless '+' eq shift @m;
		$nick{mode} = +{ map { 
			if (exists $state[$$net]{umode2txt}{$_}) {
				$state[$$net]{umode2txt}{$_} => 1 
			} else {
				warn "Unknown umode '$_'";
				();
			}
		} @m };

		my $nick = Nick->new(%nick);
		$net->nick_collide($_[3], $nick);
		();
	}, OPERTYPE => sub {
		(); # we don't particularly care
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
			dst => $nick,
			type => 'NICKINFO',
			item => 'host',
			value => $_[2],
		};
	}, FNAME => sub {
		my $net = shift;
		my $nick = $net->mynick($_[0]) or return ();
		return +{
			dst => $nick,
			type => 'NICKINFO',
			item => 'name',
			value => $_[2],
		};
	},

	FJOIN => sub {
		my $net = shift;
		my $chan = $net->chan($_[2], 1);
		my $ts = $_[3];
		my $applied = ($chan->ts() >= $ts);
		my @acts;
		push @acts, +{
			type => 'TIMESYNC',
			src => $net,
			dst => $chan,
			ts => $ts,
			wipe => 1,
		} if $chan->ts() > $ts;

		for my $nm (split / /, $_[-1]) {
			$nm =~ /(?:(.*),)?(\S+)$/ or next;
			my $nmode = $1;
			my $nick = $net->mynick($2);
			my %mh = map { $state[$$net]{pfx2txt}{$_} => 1 } split //, $nmode;
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
			my $chan = $net->chan($_);
			+{
				type => 'JOIN',
				src => $src,
				dst => $chan,
			};
		} split /,/, $_[2];
	}, FMODE => sub {
		my $net = shift;
		my $src = $net->item($_[0]);
		my $chan = $net->chan($_[2]);
		my $ts = $_[3];
		return () if $ts > $chan->ts();
		my($modes,$args) = $net->_modeargs(@_[4 .. $#_]);
		return +{
			type => 'MODE',
			src => $src,
			dst => $chan,
			mode => $modes,
			args => $args,
		};
	}, MODE => sub {
		my $net = shift;
		my $src = $net->item($_[0]);
		my $dst = $net->item($_[2]);
		if ($dst->isa('Nick')) {
			$net->_parse_umode($dst, $_[3]);
		} else {
			my($modes,$args) = $net->_modeargs(@_[3 .. $#_]);
			return +{
				type => 'MODE',
				src => $src,
				dst => $dst,
				mode => $modes,
				args => $args,
			};
		}
	}, REMSTATUS => sub {
		my $net = shift;
		my $chan = $net->chan($_[2]);
		return +{
			type => 'TIMESYNC',
			src => $net,
			dst => $chan,
			ts => $chan->ts(),
			wipe => 1,
		};
	}, FTOPIC => sub {
		() # TODO
	}, TOPIC => sub {
		() # TODO
	},

	SERVER => sub {
		my $net = shift;
		unless ($state[$$net]{auth}) {
			if ($_[3] eq $net->param('yourpass')) {
				$state[$$net]{auth} = 1;
				$net->send('BURST '.time);
			} else {
				$net->send('ERROR :Bad password');
			}
		}
		# TODO add it to the server map... if we need one
		();
	}, SQUIT => sub { 
		(); # TODO
	}, RSQUIT => sub {
		# hey, isn't that nice, I can ignore this!
		();
	}, PING => sub {
		my $net = shift;
		my $from = $_[3] || $net->cparam('linkname');
		$net->send($net->cmd2($from, 'PONG', $from, $_[2]));
		();
	}, BURST => sub {
		my $net = shift;
		return () if $state[$$net]{auth} != 1;
		$state[$$net]{auth} = 2;
		my @out;
		for my $id (keys %Janus::nets) {
			my $new = $Janus::nets{$id};
			next if $new->isa('Interface') || $id eq $net->id();
			push @out, $net->cmd2($net->cparam('linkname'), SERVER => "$id.janus", '*', 1, $new->netname());
		}
		$net->send(@out);
		();
	}, CAPAB => sub {
		my $net = shift;
		if ($_[2] eq 'MODULES') {
			$net->module_add($_) for split /,/, $_[-1];
		} elsif ($_[2] eq 'CAPABILITIES') {
			$_ = $_[3];
			while (s/^\s*(\S+)=(\S+)//) {
				$state[$$net]{CAPAB}{$1} = $2;
			}
# NICKMAX=32 HALFOP=1 CHANMAX=65 MAXMODES=20 IDENTMAX=12 MAXQUIT=255 MAXTOPIC=307 MAXKICK=255 MAXGECOS=128 
# MAXAWAY=200 IP6NATIVE=1 IP6SUPPORT=1 PROTOCOL=1105 PREFIX=(qaohv)~&@%+ CHANMODES=Ibe,k,jl,CKMNOQRTcimnprst
		} elsif ($_[2] eq 'END') {
			# yep, we lie about all this.
			my $mods = join ',', sort grep $_ ne 'CORE', keys %{$modules[$$net]};
			my $capabs = join ' ', sort map {
				my($k,$v) = ($_, $state[$$net]{CAPAB}{$_});
				$k = undef if $k eq 'CHALLENGE'; # TODO generate our own challenge and use SHA256 passwords
				$k ? "$k=$v" : ();
			} keys %{$state[$$net]{CAPAB}};
			$net->send('CAPAB START');
			$net->send('CAPAB MODULES '.$1) while $mods =~ s/(.{1,450})(,|$)//;
			$net->send('CAPAB CAPABILITIES :'.$1) while $capabs =~ s/(.{1,450})( |$)//;
	        $net->send('CAPAB END');
			$net->send($net->cmd1(SERVER => $net->param('linkname'), $net->param('mypass'), 0, 'Janus Network Link'));
			$_ = $state[$$net]{CAPAB}{PREFIX};
			my(%p2t,%t2p);
			while (s/\((.)(.*)\)(.)/($2)/) {
				my $txt = $state[$$net]{cmode2txt}{$1};
				$t2p{$txt} = $3;
				$p2t{$3} = $txt;
			}
			$state[$$net]{pfx2txt} = \%p2t;
			$state[$$net]{txt2pfx} = \%t2p;
			# TODO verify the set of CHANMODES is identical
			# note without +qa prefix, they appear in the 'list' part of CHANMODES
		} # ignore START and any others
		();
	},
	PONG => \&ignore,
	VERSION => \&ignore,
	ADDLINE => \&ignore, 
	GLINE => \&ignore, 
	ELINE => \&ignore, 
	ZLINE => \&ignore, 
	QLINE => \&ignore, 
	SVSNICK => sub {
		() # TODO
	}, SVSMODE => sub {
		() # TODO
	},
	REHASH => \&ignore,
	MODULES => \&ignore,
	ENDBURST => sub {
		my $net = shift;
		return +{
			type => 'LINKED',
			net => $net,
			sendto => [ values %Janus::nets ],
		};
	},

	PRIVMSG => \&nc_msg,
	NOTICE => \&nc_msg,
	OPERNOTICE => \&ignore,
	MODENOTICE => \&ignore,
	SNONOTICE => \&ignore,
	METADATA => sub {
		my $net = $_[0];
		my $key = $_[4];
		my $mdh = $meta[$$net]{$key};
		return () unless $mdh;
		$mdh->(@_);
	},
	IDLE => \&ignore,
	PUSH => \&ignore,
	TIME => \&ignore,
	TIMESET => \&ignore,
  }, acts => {
	NETLINK => sub {
		my($net,$act) = @_;
		my $new = $act->{net};
		my $id = $new->id();
		return () unless $state[$$net]{auth};
		if ($net->id() eq $id) {
			();
		} else {
			return $net->cmd2($net->cparam('linkname'), SERVER => "$id.janus", '*', 1, $new->netname());
		}
	}, NETSPLIT => sub {
		my($net,$act) = @_;
		my $gone = $act->{net};
		my $id = $gone->id();
		my $msg = $act->{msg} || 'Excessive Core Radiation';
		$net->cmd2($net->cparam('linkname'), SQUIT => "$id.janus", $msg),
	}, CONNECT => sub {
		my($net,$act) = @_;
		my $nick = $act->{dst};
		return () if $act->{net}->id() ne $net->id();
		
		return $net->_connect_ifo($nick);
	}, RECONNECT => sub {
		my($net,$act) = @_;
		my $nick = $act->{dst};
		return () if $act->{net}->id() ne $net->id();

		if ($act->{killed}) {
			my @out = $net->_connect_ifo($nick);
			for my $chan (@{$act->{reconnect_chans}}) {
				next unless $chan->is_on($net);
				my $mode = join '', map {
					$chan->has_nmode($_, $nick) ? $state[$$net]{txt2pfx}{$_} : ''
				} qw/n_voice n_halfop n_op n_admin n_owner/;
				push @out, $net->cmd1(FJOIN => $chan, $chan->ts(), $mode.','.$nick->str($net));
			}
			return @out;
		} else {
			return $net->cmd2($act->{from}, NICK => $act->{to}, $nick->ts());
		}
	}, JOIN => sub {
		my($net,$act) = @_;
		my $chan = $act->{dst};
		if ($act->{src}->homenet()->id() eq $net->id()) {
			print "ERR: Trying to force channel join remotely (".$act->{src}->gid().$chan->str($net).")\n";
			return ();
		}
		my $mode = '';
		if ($act->{mode}) {
			$mode .= $state[$$net]{txt2pfx}{$_} for keys %{$act->{mode}};
		}
		$net->cmd1(FJOIN => $chan, $chan->ts(), $mode.','.$net->_out($act->{src}));
	}, PART => sub {
		my($net,$act) = @_;
		$net->cmd2($act->{src}, PART => $act->{dst}, $act->{msg});
	}, KICK => sub {
		my($net,$act) = @_;
		$net->cmd2($act->{src}, KICK => $act->{dst}, $act->{kickee}, $act->{msg});
	}, MODE => sub {
		my($net,$act) = @_;
		my $src = $act->{src};
		my @interp = $net->_mode_interp($act);
		return () unless @interp;
		return () if @interp == 1 && $interp[0] =~ /^[+-]+$/;
		return $net->cmd2($src, MODE => $act->{dst}, @interp);
	}, NICKINFO => sub {
		my($net,$act) = @_;
		if ($act->{item} eq 'host') {
			return $net->cmd2($act->{dst}, FHOST => $act->{value});
		} elsif ($act->{item} eq 'name') {
			return $net->cmd2($act->{dst}, FNAME => $act->{value});
		} elsif ($act->{item} eq 'away') {
			return $net->cmd2($act->{dst}, AWAY => defined $act->{value} ? $act->{value} : ());
		}
		return ();
	},
	MSG => sub {
		my($net,$act) = @_;
		return if $act->{dst}->isa('Network');
		my $type = $act->{msgtype} || 1;
		$type = 
			$type == 1 ? 'PRIVMSG' :
			$type == 2 ? 'NOTICE' :
			sprintf '%03d', $type;
		my @msg = ref $act->{msg} eq 'ARRAY' ? @{$act->{msg}} : $act->{msg};
		$net->cmd2($act->{src}, $type, ($act->{prefix} || '').$net->_out($act->{dst}), @msg);
	}, PING => sub {
		my($net,$act) = @_;
		$net->cmd2($net->cparam('linkname'), PING => $net->cparam('linkto'));
	},
}

});

$moddef{$_} or $moddef{$_} = {} for qw/m_globops.so m_invisible.so m_inviteexception.so m_joinflood.so m_knock.so m_noctcp.so m_nokicks.so m_nonicks.so m_nonotice.so m_operchans.so m_services.so m_showwhois.so/;

1;
