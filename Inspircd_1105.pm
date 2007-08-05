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

our($VERSION) = '$Rev$' =~ /(\d+)/;

__PERSIST__
persist @sendq     :Field;
persist @servers   :Field;
persist @serverdsc :Field;

persist @modules   :Field; # {module} => definition - List of active modules
persist @meta      :Field; # key => sub{} for METADATA command
persist @fromirc   :Field; # command => sub{} for IRC commands
persist @act_hooks :Field; # type => module => sub{} for Janus Action => output

persist @auth      :Field; # 0/undef = unauth connection; 1 = authed, in burst; 2 = after burst
persist @capabs    :Field;

persist @txt2cmode :Field; # quick lookup hashes for translation in/out of janus
persist @cmode2txt :Field;
persist @txt2umode :Field;
persist @umode2txt :Field;
persist @txt2pfx   :Field;
persist @pfx2txt   :Field;
__CODE__

sub _init :Init {
	my $net = shift;
	$sendq[$$net] = [];
	$net->module_add('CORE');
	$auth[$$net] = 0;
}

sub ignore { () }

my %moddef;

sub module_add {
	my($net,$name) = @_;
	my $mod = $moddef{$name} or do {
		$net->send($net->cmd2($Janus::interface, OPERNOTICE => "Unknown module $name, janus may become desynced if it is used"));
		return;
	};
	return if $modules[$$net]{$name};
	$modules[$$net]{$name} = $mod;
	if ($mod->{cmode}) {
		for my $cm (keys %{$mod->{cmode}}) {
			my $txt = $mod->{cmode}{$cm};
			warn "Overriding mode $cm = $txt" if $cmode2txt[$$net]{$cm} || $txt2cmode[$$net]{$txt};
			$cmode2txt[$$net]{$cm} = $txt;
			$txt2cmode[$$net]{$txt} = $cm;
		}
	}
	if ($mod->{umode}) {
		for my $um (keys %{$mod->{umode}}) {
			my $txt = $mod->{umode}{$um};
			warn "Overriding umode $um = $txt" if $umode2txt[$$net]{$um} || $txt2umode[$$net]{$txt};
			$umode2txt[$$net]{$um} = $txt;
			$txt2umode[$$net]{$txt} = $um;
		}
	}
	if ($mod->{umode_hook}) {
		for my $txt (keys %{$mod->{umode}}) {
			warn "Overriding umode $txt" if $txt2umode[$$net]{$txt} && !$mod->{umode}{$txt2umode[$$net]{$txt}};
			$txt2umode[$$net]{$txt} = $mod->{umode_hook}{$txt};
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

sub module_remove {
	my($net,$name) = @_;
	my $mod = delete $modules[$$net]{$name} or do {
		$net->send($net->cmd2($Janus::interface, OPERNOTICE => "Could not unload moule $name: not loaded"));
		return;
	};
	$net->send($net->cmd2($Janus::interface, OPERNOTICE => "Module removal not implemented yet!")); # TODO
}

sub cmode2txt {
	my($net,$cm) = @_;
	$cmode2txt[$$net]{$cm};
}

sub txt2cmode {
	my($net,$tm) = @_;
	$txt2cmode[$$net]{$tm};
}

sub nicklen { 
	my $net = shift;
	($capabs[$$net]{NICKMAX} || 32) - 1;
}

sub debug {
	print @_, "\n";
}

sub str {
	my $net = shift;
	$net->id().'.janus';
}

sub intro :Cumulative {
	my($net,$param) = @_;
	my @out;
	push @out, ['INIT', 'CAPAB START'];
	# we cannot continue until we get the remote CAPAB list so we can
	# forge the module list. However, we can set up the other server introductions
	# as they will be sent after auth is done
	push @out, $net->ncmd(VERSION => 'Janus Hub');
	for my $id (keys %Janus::nets) {
		my $new = $Janus::nets{$id};
		next if $new->isa('Interface') || $id eq $net->id();
		push @out, $net->ncmd(SERVER => "$id.janus", '*', 1, $new->netname());
		push @out, $net->cmd2("$id.janus", VERSION => 'Remote Janus Server: '.ref $new);
	}
	$net->send(@out);
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
	unless ($auth[$$net] || $cmd eq 'CAPAB' || $cmd eq 'SERVER') {
		$net->send(['INIT', 'ERROR :Not authorized yet']);
		return ();
	}
	$cmd = $fromirc[$$net]{$cmd} || $cmd;
	$cmd = $fromirc[$$net]{$cmd} || $cmd if $cmd && !ref $cmd; # allow one layer of indirection
	unless ($cmd && ref $cmd) {
		$net->send($net->cmd2($Janus::interface, OPERNOTICE => "Unknown command $cmd, janus is possibly desynced"));
		debug "Unknown command '$cmd'";
		return ();
	}
	$cmd->($net,@args);
}

sub send {
	my $net = shift;
	for my $act (@_) {
		if (ref $act && ref $act eq 'HASH') {
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
	my $q = '';
	if ($auth[$$net] == 3) {
		for my $i (@{$sendq[$$net]}, '') {
			if (ref $i) {
				$q .= join "\n", @$i[1..$#$i],'';
			} else {
				$q .= $i."\n";
			}
		}
		$q =~ s/\n+/\r\n/g;
		$sendq[$$net] = [];
	} else {
		my @delayed;
		for my $i (@{$sendq[$$net]}) {
			if (ref $i) {
				$q .= join "\n", @$i[1..$#$i],'';
			} else {
				push @delayed, $i;
			}
		}
		$q =~ s/\n+/\r\n/g;
		$sendq[$$net] = \@delayed;
		$auth[$$net] = 3 if $auth[$$net] == 2;
	}
	debug '    OUT@'.$net->id().' '.$_ for split /\r\n/, $q;
	$q;
}

sub _connect_ifo {
	my ($net, $nick) = @_;

	my @out;

	my $mode = '+';
	for my $m ($nick->umodes()) {
		next unless exists $txt2umode[$$net]{$m};
		if (ref $txt2umode[$$net]{$m}) {
			push @out, $txt2umode[$$net]{$m}->($net, $nick, '+'.$m);
		} else {
			$mode .= $txt2umode[$$net]{$m};
		}
	}
	
	my $srv = $nick->homenet()->id() . '.janus';
	$srv = $net->cparam('linkname') if $srv eq 'janus.janus';

	my $ip = $nick->info('ip') || '0.0.0.0';
	$ip = '0.0.0.0' if $ip eq '*';
	unshift @out, $net->cmd2($srv, NICK => $nick->ts(), $nick, $nick->info('host'), $nick->info('vhost'),
		$nick->info('ident'), $mode, $ip, $nick->info('name'));
	if ($nick->has_mode('oper')) {
		my $type = $nick->info('opertype') || 'IRC Operator';
		my $len = $net->nicklen() - 9;
		$type = substr $type, 0, $len;
		$type .= ' (remote)';
		$type =~ s/ /_/g;
		push @out, $net->cmd2($nick, OPERTYPE => $type);
	}
	push @out, $net->cmd2($nick, AWAY => $nick->info('away')) if $nick->info('away');
	
	@out;
}

sub process_capabs {
	my $net = shift;
	# NICKMAX=32 - done below in nicklen()
	# HALFOP=1
	if ($capabs[$$net]{HALFOP}) {
		$cmode2txt[$$net]{h} = 'n_halfop';
		$txt2cmode[$$net]{n_halfop} = 'h';
	}
	# CHANMAX=65 - not applicable, we never send channels we have not heard before
	# MAXMODES=20 - TODO
	# IDENTMAX=12 - TODO
	# MAXQUIT=255 - TODO
	# MAXTOPIC=307 - TODO
	# MAXKICK=255 - TODO
	# MAXGECOS=128 -TODO
	# MAXAWAY=200 - TODO
	# IP6NATIVE=1 IP6SUPPORT=1 - we currently require IPv6 support, and claim to be native because we're cool like that :)
	# PROTOCOL=1105 - TODO
	# PREFIX=(qaohv)~&@%+ 
	local $_ = $capabs[$$net]{PREFIX};
	my(%p2t,%t2p);
	while (s/\((.)(.*)\)(.)/($2)/) {
		my $txt = $cmode2txt[$$net]{$1};
		$t2p{$txt} = $3;
		$p2t{$3} = $txt;
	}
	$pfx2txt[$$net] = \%p2t;
	$txt2pfx[$$net] = \%t2p;

	# CHANMODES=Ibe,k,jl,CKMNOQRTcimnprst
	my %split2c;
	$split2c{substr $_,0,1}{$_} = $txt2cmode[$$net]{$_} for keys %{$txt2cmode[$$net]};

	# Without a prefix character, nick modes such as +qa appear in the "l" section
	exists $t2p{$_} or $split2c{l}{$_} = $split2c{n}{$_} for keys %{$split2c{n}};

	my $expect = join ',', map { join '', sort values %{$split2c{$_}} } qw(l v s r);

	unless ($expect eq $capabs[$$net]{CHANMODES}) {
		$net->send($net->ncmd(OPERNOTICE => 'Possible desync - CHANMODES do not match module list: '.
				"expected $expect, got $capabs[$$net]{CHANMODES}"));
	}
}

# IRC Parser
# Arguments:
# 	$_[0] = Network
# 	$_[1] = source (not including leading ':') or 'undef'
# 	$_[2] = command (for multipurpose subs)
# 	3 ... = arguments to the irc line; last element has the leading ':' stripped
# Return:
#  list of hashrefs containing the Action(s) represented (can be empty)

sub _parse_umode {
	my($net, $nick, $mode) = @_;
	my @mode;
	my $pm = '+';
	for (split //, $mode) {
		if (/[-+]/) {
			$pm = $_;
		} else {
			my $txt = $umode2txt[$$net]{$_} or do {
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

sub ncmd {
	my $net = shift;
	$net->cmd2($net->cparam('linkname'), @_);
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
	'm_alias.so' => { },
	'm_alltime.so' => {
		cmds => { ALLTIME => \&ignore },
	},
	'm_antibear.so' => { },
	'm_antibottler.so' => { },
	# This can be set in config to hide ops too, see
	# http://www.inspircd.org/wiki/Modules/auditorium
	'm_auditorium.so' => {
		cmode => { u => 'r_auditorium' },
	},
	'm_banexception.so' => {
		cmode => { e => 'l_except' },
	},
	'm_banredirect.so' => { }, # this just adds syntax to channel bans
	'm_blockamsg.so' => { },
	'm_blockcaps.so' => {
		cmode => { P => 'r_blockcaps' }
	},
	'm_blockcolor.so' => {
		cmode => { c => 'r_colorblock' },
	},
	'm_botmode.so' => {
		umode => { B => 'bot' },
	},
	'm_cban.so' => { cmds => { CBAN => \&ignore } }, # janus needs localjoin to link, so we don't care
	'm_censor.so' => {
		cmode => { G => 'r_badword' },
		umode => { G => 'badword' },
	},
	'm_hidechans.so' => {
		umode => { I => 'hide_chans' },
	},
	'm_cgiirc.so' => { },
	'm_chancreate.so' => { },
	'm_chanfilter.so' => {
		cmode => { g => 'l_badwords' },
	},
	'm_chanprotect.so' => {
		cmode => {
			a => 'n_admin',
			'q' => 'n_owner'
		},
	},
	'm_check.so' => { },
	
	'm_chghost.so' => {
		cmds => {
			CHGHOST => sub {
				my $net = shift;
				my $dst = $net->mynick($_[2]) or return ();
				return +{
					type => 'NICKINFO',
					src => $net->item($_[0]),
					dst => $dst,
					item => 'vhost',
					value => $_[3],
				};
			}
		},
	},
	'm_chgident.so' => {
		cmds => {
			CHGIDENT => sub {
				my $net = shift;
				my $dst = $net->mynick($_[2]) or return ();
				return +{
					type => 'NICKINFO',
					src => $net->item($_[0]),
					dst => $dst,
					item => 'ident',
					value => $_[3],
				};
			}
		}, acts => {
			NICKINFO => sub {
				my($net,$act) = @_;
				if ($act->{item} eq 'ident') {
					# prefer setident's action
					return () if $modules[$$net]{'m_setident.so'};
					return $net->cmd2($act->{dst}, CHGIDENT => $act->{dst}, $act->{value});
				}
				();
			},
		},
	},
	'm_chgname.so' => {
		cmds => {
			CHGNAME => sub {
				my $net = shift;
				my $dst = $net->mynick($_[2]) or return ();
				return +{
					type => 'NICKINFO',
					src => $net->item($_[0]),
					dst => $dst,
					item => 'name',
					value => $_[3],
				};
			}
		},
	},
	'm_cloaking.so' => {
		umode => { x => 'vhost_x' }
	},
	'm_clones.so' => { },
	'm_conn_join.so' => { },
	'm_conn_umodes.so' => { },
	'm_conn_waitpong.so' => { },
	'm_connflood.so' => { },
	'm_cycle.so' => { },
	'm_dccallow.so' => { cmds => { DCCALLOW => \&ignore } },
	'm_deaf.so' => {
		umode => { d => 'deaf_chan' }
	},
	'm_denychans.so' => { },
	'm_devoice.so' => {
		cmds => {
			DEVOICE => sub {
				my $net = shift;
				my $nick = $net->mynick($_[0]) or return ();
				return +{
					type => 'MODE',
					src => $net,
					dst => $net->chan($_[2]),
					modes => [ '-n_voice' ],
					args => [ $nick ],
				};
			},
		},
	},
	'm_dnsbl.so' => { },
	'm_filter.so' => { cmds => { FILTER => \&ignore } },
	'm_filter_pcre.so' => { },
	'm_foobar.so' => { },
	'm_globalload.so' => { 
		cmds => { 
			GLOADMODULE => sub {
				my $net = shift;
				$net->module_add($_[2]);
			},
			GUNLOADMODULE => sub {
				my $net = shift;
				$net->module_remove($_[2]);
			},
			GRELOADMODULE => \&ignore,
		},
	},
	'm_globops.so' => {
		cmds => { GLOBOPS => \&ignore },
	},
	'm_helpop.so' => {
		umode => { h => 'helpop' },
		cmds => { HELPOP => \&ignore },
	},
	'm_hideoper.so' => {
		umode => { H => 'hideoper' }
	},
	'm_hostchange.so' => { },
	'm_http_client.so' => { },
	'm_httpd.so' => { },
	'm_httpd_stats.so' => { },
	'm_ident.so' => { },
	'm_invisible.so' => {
		# sadly, you are NOT invisible to remote users :P
		umode => { Q => 'hiddenabusiveoper' }
	},
	'm_inviteexception.so' => {
		cmode => { I => 'l_invex' }
	},
	'm_joinflood.so' => {
		cmode => { j => 's_joinlimit' }
	},
	'm_jumpserver.so' => { },
	'm_kicknorejoin.so' => {
		cmode => { J => 's_kicknorejoin' }
	},
	'm_knock.so' => {
		# TODO translate INVITE and KNOCK across janus 
		cmode => { K => 'r_noknock' }
	},
	'm_lockserv.so' => { },
	'm_md5.so' => { },
	'm_messageflood.so' => {
		cmode => { f => 's_flood' }
	},
	'm_namesx.so' => { },
#	'm_nicklock.so' => { }, # TODO go back and unlock the nick
	'm_noctcp.so' => {
		cmode => { C => 'r_ctcpblock' }
	},
	'm_noinvite.so' => {
		cmode => { V => 'r_noinvite' }
	},
	'm_nokicks.so' => {
		cmode => { Q => 'r_nokick' }
	},
	'm_nonicks.so' => {
		cmode => { N => 'r_norenick' }
	},
	'm_nonotice.so' => {
		cmode => { T => 'r_noticeblock' }
	},
	'm_oper_hash.so' => { },
	'm_operchans.so' => {
		cmode => { O => 'r_oper' }
	},
	'm_operjoin.so' => { },
	'm_operlevels.so' => { },
	'm_operlog.so' => { },
	'm_opermodes.so' => { },
	'm_opermotd.so' => { },
	'm_override.so' => { },
	'm_randquote.so' => { },
	'm_redirect.so' => {
		cmode => { L => 's_forward' }
	},
	'm_regonlycreate.so' => { },
	'm_remove.so' => {
		cmds => {
			FPART => 'KICK',
			REMOVE => sub { 
				# this is stupid. Three commands that do the SAME EXACT THING...
				my $net = shift;
				my $nick = $net->nick($_[2]) or return ();
				return +{
					type => 'KICK',
					src => $net->item($_[0]),
					dst => $net->chan($_[3]),
					kickee => $nick,
					msg => $_[4],
				};
			},
		},
	},
	'm_restrictbanned.so' => { },
	'm_restrictchans.so' => { },
	'm_restrictmsg.so' => { },
	'm_safelist.so' => { },
	'm_sajoin.so' => {
		cmds => { 'SAJOIN' => \&ignore },
	},
	'm_samode.so' => { },
	'm_sanick.so' => {
		cmds => {
			SANICK => sub {
				my $net = shift;
				my $nick = $net->nick($_[2]);
				if ($nick->homenet()->id() eq $net->id()) {
					# accept as normal nick change
					return +{
						type => 'NICK',
						src => $nick,
						dst => $nick,
						nick => $_[3],
						nickts => time,
					};
				}
				# reject
				$net->send($net->cmd2($_[2], NICK => $_[3]));
				();
			},
		},
	},
	'm_sapart.so' => { 
		cmds => { 'SAPART' => \&ignore },
	},
	'm_saquit.so' => {
		cmds => { 'SAQUIT' => 'KILL' },
	},
	'm_securelist.so' => { },
	'm_seenicks.so' => { },
	'm_services.so' => {
		cmode => {
			r => 'r_register',
			R => 'r_reginvite',
			M => 'r_regmoderated'
		},
		umode => {
			r => 'registered',
			R => 'deaf_regpriv'
		},
		umode_hook => {
			registered => \&ignore,
		},
	},
	'm_services_account.so' => {
		cmode => {
			R => 'r_reginvite',
			M => 'r_regmoderated'
		},
		umode => { R => 'deaf_regpriv' },
		metadata => {
			accountname => sub {
				my $net = shift;
				my $nick = $net->mynick($_[2]) or return ();
				return +{
					type => 'UMODE',
					dst => $nick,
					mode => [ $_[4] eq '' ? '-registered' : '+registered' ],
				};
			},
		},
	},
	'm_sethost.so' => {
		cmds => {
			SETHOST => sub {
				my $net = shift;
				my $nick = $net->mynick($_[0]) or return ();
				return +{
					type => 'NICKINFO',
					src => $nick,
					dst => $nick,
					item => 'vhost',
					value => $_[2],
				};
			}
		},
	},
	'm_setident.so' => {
		cmds => {
			SETIDENT => sub {
				my $net = shift;
				my $nick = $net->mynick($_[0]) or return ();
				return +{
					type => 'NICKINFO',
					src => $nick,
					dst => $nick,
					item => 'ident',
					value => $_[2],
				};
			}
		}, acts => {
			NICKINFO => sub {
				my($net,$act) = @_;
				if ($act->{item} eq 'ident') {
					return $net->cmd2($act->{dst}, SETIDENT => $act->{value});
				}
				();
			},
		},
	},
	'm_setname.so' => {
		cmds => {
			SETNAME => sub {
				my $net = shift;
				my $dst = $net->mynick($_[0]) or return ();
				return +{
					type => 'NICKINFO',
					src => $dst,
					dst => $dst,
					item => 'name',
					value => $_[2],
				};
			}
		},
	},
	'm_setidle.so' => { },
	'm_sha256.so' => { },
	'm_showwhois.so' => {
		umode => { W => 'whois_notice' }
	},
	'm_silence.so' => { cmds => { SILENCE => \&ignore } },
	'm_silence_ext.so' => { cmds => { SILENCE => \&ignore } },
	'm_spanningtree.so' => { },
	'm_spy.so' => { },
	'm_sslmodes.so' => {
		cmode => { z => 'r_sslonly' },
	},
	'm_ssl_dummy.so' => {
		metadata => {
			ssl => sub {
				my $net = shift;
				my $nick = $net->mynick($_[2]) or return ();
				warn "Unknown SSL value $_[4]" unless $_[4] eq 'ON';
				return +{
					type => 'UMODE',
					dst => $nick,
					mode => [ '+ssl' ],
				};
			},
		},
		umode_hook => {
			ssl => sub {
				my($net, $nick, $pm) = @_;
				if ($pm eq '+ssl') {
					return $net->ncmd(METADATA => $nick, ssl => 'ON');
				} else {
					warn 'Inspircd is incapable of unsetting SSL';
					return ();
				}
			},
		},
	},
	'm_stripcolor.so' => {
		umode => { S => 'colorstrip' },
		cmode => { S => 'r_colorstrip' }
	},
	'm_svshold.so' => { },
	'm_swhois.so' => {
		metadata => {
			swhois => sub {
				my $net = shift;
				my $nick = $net->mynick($_[2]) or return ();
				return +{
					type => 'NICKINFO',
					src => $net->item($_[0]),
					dst => $_[2],
					item => 'swhois',
					value => $_[4],
				};
			},
		},
		cmds => {
			SWHOIS => sub {
				my $net = shift;
				return +{
					type => 'NICKINFO',
					src => $net->item($_[0]),
					dst => $_[2],
					item => 'swhois',
					value => $_[3],
				};
			},
		},
		acts => {
			NICKINFO => sub {
				my($net,$act) = @_;
				if ($act->{item} eq 'swhois') {
					return $net->ncmd(METADATA => $act->{dst}, 'swhois', $act->{value});
				}
				()
			},
		},
	},
	'm_taxonomy.so' => { },
	'm_testcommand.so' => { },
	'm_timedbans.so' => { cmds => { TBAN => \&ignore } },
	'm_tline.so' => { },
	'm_uhnames.so' => { },
	'm_uninvite.so' => { },
	'm_userip.so' => { },
	'm_vhost.so' => { }, # routed as normal FHOST
	'm_watch.so' => { },
 	'm_xmlsocket.so' => { },
CORE => {
  cmode => {
		b => 'l_ban',
		i => 'r_invite',
		k => 'v_key',
		l => 's_limit',
		'm' => 'r_moderated',
		n => 'r_mustjoin',
		o => 'n_op',
		p => 'r_private',
		's' => 'r_secret',
		t => 'r_topic',
		v => 'n_voice',
  },
  umode => {
		i => 'invisible',
		n => 'snomask',
		o => 'oper',
		's' => 'globops', # technically, server notices
		w => 'wallops',
  },
  cmds => {
  	NICK => sub {
		my $net = shift;
		if (@_ < 10) {
			my $nick = $net->mynick($_[0]) or return ();
			return +{
				type => 'NICK',
				src => $nick,
				dst => $nick,
				nick => $_[2],
				nickts => (@_ == 4 ? $_[3] : time),
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
				ip => $ip,
				name => $_[-1],
			},
		);
		my @m = split //, $_[7];
		warn unless '+' eq shift @m;
		$nick{mode} = +{ map {
			if (exists $umode2txt[$$net]{$_}) {
				$umode2txt[$$net]{$_} => 1
			} else {
				warn "Unknown umode '$_'";
				();
			}
		} @m };

		my $nick = Nick->new(%nick);
		my($good, @out) = $net->nick_collide($_[3], $nick);
		if ($good) {
			push @out, +{
				type => 'NEWNICK',
				dst => $nick,
			};
		} else {
			$net->send($net->cmd1(KILL => $_[3], 'hub.janus (Nick collision)'));
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

		if ($dst->homenet()->id() eq $net->id()) {
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
		push @acts, +{
			type => 'TIMESYNC',
			src => $net,
			dst => $chan,
			ts => $ts,
			oldts => $chan->ts(),
			wipe => 1,
		} if $chan->ts() > $ts;

		for my $nm (split / /, $_[-1]) {
			$nm =~ /(?:(.*),)?(\S+)$/ or next;
			my $nmode = $1;
			my $nick = $net->mynick($2);
			my %mh = map { $pfx2txt[$$net]{$_} => 1 } split //, $nmode;
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
			oldts => $chan->ts(),
			wipe => 1,
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
		};
	}, TOPIC => sub {
		my $net = shift;
		return +{
			type => 'TOPIC',
			src => $net->item($_[0]),
			dst => $net->chan($_[2]),
			topicts => time,
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
	}, 

	SERVER => sub {
		my $net = shift;
		unless ($auth[$$net]) {
			if ($_[3] eq $net->param('yourpass')) {
				$auth[$$net] = 1;
				$net->send(['INIT', 'BURST '.time, $net->ncmd(VERSION => 'Janus')]);
			} else {
				$net->send(['INIT', 'ERROR :Bad password']);
			}
		} else {
			# recall parent
			$servers[$$net]{lc $_[2]} = lc $_[0];
		}
		$serverdsc[$$net]{lc $_[2]} = $_[-1];
		+{
			type => 'BURST',
			net => $net,
		};
	}, SQUIT => sub {
		my $net = shift;
		my $netid = $net->id();
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
		print 'Lost servers: '.join(' ', sort keys %sgone)."\n";
		delete $servers[$$net]{$_} for keys %sgone;
		delete $serverdsc[$$net]{$_} for keys %sgone;

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
		my $net = shift;
		return () if $auth[$$net] != 1;
		$auth[$$net] = 2;
		();
	}, CAPAB => sub {
		my $net = shift;
		if ($_[2] eq 'MODULES') {
			$net->module_add($_) for split /,/, $_[-1];
		} elsif ($_[2] eq 'CAPABILITIES') {
			$_ = $_[3];
			while (s/^\s*(\S+)=(\S+)//) {
				$capabs[$$net]{$1} = $2;
			}
		} elsif ($_[2] eq 'END') {
			# yep, we lie about all this.
			my $mods = join ',', sort grep $_ ne 'CORE', keys %{$modules[$$net]};
			my $capabs = join ' ', sort map {
				my($k,$v) = ($_, $capabs[$$net]{$_});
				$k = undef if $k eq 'CHALLENGE'; # TODO generate our own challenge and use SHA256 passwords
				$k ? "$k=$v" : ();
			} keys %{$capabs[$$net]};
			my @out = 'INIT';
			push @out, 'CAPAB MODULES '.$1 while $mods =~ s/(.{1,495})(,|$)//;
			push @out, 'CAPAB CAPABILITIES :'.$1 while $capabs =~ s/(.{1,450})( |$)//;
			push @out, 'CAPAB END';
			push @out, $net->cmd1(SERVER => $net->param('linkname'), $net->param('mypass'), 0, 'Janus Network Link');
			$net->send(\@out);
			$net->process_capabs();
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
	PONG => \&ignore, # already got ->ponged() above
	VERSION => \&ignore,
	ADDLINE => \&ignore, # TODO convert to BANLINE action
	GLINE => \&ignore,
	ELINE => \&ignore,
	ZLINE => \&ignore,
	QLINE => \&ignore,
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
	},
	SVSMODE => 'MODE',
	REHASH => sub {
		return +{
			type => 'REHASH',
			sendto => [],
		};
	},
	MODULES => \&ignore,
	ENDBURST => sub {
		my $net = shift;
		return (+{
			type => 'LINKED',
			net => $net,
			sendto => [ values %Janus::nets ],
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
		} elsif ($_[2] =~ /(.?)(#\S*)/) {
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
	METADATA => sub {
		my $net = $_[0];
		my $key = $_[4];
		my $mdh = $meta[$$net]{$key};
		return () unless $mdh;
		$mdh->(@_);
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
			# we have to assume the requesting server is one like unreal that needs the whole thing sent
			# across. The important part for remote inspircd servers is the 317 line
			my $home_srv = $src->info('home_server');
			my @msgs = (
				[ 311, $src->info('ident'), $src->info('vhost'), '*', $src->info('name') ],
				[ 312, $home_srv, $serverdsc[$$net]{$home_srv} ],
			);
			push @msgs, [ 313, 'is a '.($src->info('opertype') || 'Unknown Oper') ] if $src->has_mode('oper');
			push @msgs, (
				[ 317, $_[4], $_[3], 'seconds idle, signon time'],
				[ 318, 'End of /WHOIS list' ],
			);
			return map +{
				type => 'MSG',
				src => $net,
				dst => $dst,
				msgtype => $_->[0], # first part of message
				msg => [$src, @$_[1 .. $#$_] ], # source nick, rest of message array
			}, @msgs;
		}
	}, PUSH => sub {
		my $net = shift;
		my $dst = $net->nick($_[2]) or return ();
		my($rmsg, $txt) = split /\s+:/, $_[-1], 2;
		my @msg = split /\s+/, $rmsg;
		push @msg, $txt if defined $txt;
		unshift @msg, undef unless $msg[0] =~ s/^://;
		
		if ($dst->info('_is_janus')) {
			# a PUSH to the janus nick. Don't send any events, for one.
			# However, it might be something we asked about, like the MODULES output
			if (@msg == 4 && $msg[1] eq '900' && $msg[0] && $msg[0] eq $net->cparam('linkto')) {
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
		return unless @_ == 4;
		$net->send($net->cmd2(@_[2,1,0,3], time));
		();
	},
	TIMESET => \&ignore,
  }, acts => {
	NETLINK => sub {
		my($net,$act) = @_;
		my $new = $act->{net};
		my $id = $new->id();
		return () if $net->id() eq $id;
		return (
			$net->ncmd(SERVER => "$id.janus", '*', 1, $new->netname()),
			$net->ncmd(OPERNOTICE => "Janus network $id (".$new->netname().") is now linked"),
			$net->cmd2("$id.janus", VERSION => 'Remote Janus Server: '.ref $id),
		);
	}, NETSPLIT => sub {
		my($net,$act) = @_;
		my $gone = $act->{net};
		my $id = $gone->id();
		my $msg = $act->{msg} || 'Excessive Core Radiation';
		return (
			$net->ncmd(OPERNOTICE => "Janus network $id (".$gone->netname().") has delinked: $msg"),
			$net->ncmd(SQUIT => "$id.janus", $msg),
		);
	}, CONNECT => sub {
		my($net,$act) = @_;
		my $nick = $act->{dst};
		return () if $act->{net}->id() ne $net->id();
		my @out = $net->_connect_ifo($nick);
		push @out, $net->cmd2($nick, MODULES => $net->cparam('linkto')) if $nick->info('_is_janus');
		@out;
	}, RECONNECT => sub {
		my($net,$act) = @_;
		my $nick = $act->{dst};
		return () if $act->{net}->id() ne $net->id();

		if ($act->{killed}) {
			my @out = $net->_connect_ifo($nick);
			for my $chan (@{$act->{reconnect_chans}}) {
				next unless $chan->is_on($net);
				my $mode = join '', map {
					$chan->has_nmode($_, $nick) ? ($txt2pfx[$$net]{$_} || '') : ''
				} qw/n_voice n_halfop n_op n_admin n_owner/;
				push @out, $net->cmd1(FJOIN => $chan, $chan->ts(), $mode.','.$nick->str($net));
			}
			return @out;
		} else {
			return $net->cmd2($act->{from}, NICK => $act->{to}, $nick->ts());
		}
	}, NICK => sub {
		my($net,$act) = @_;
		my $id = $net->id();
		$net->cmd2($act->{from}{$id}, NICK => $act->{to}{$id});
	}, UMODE => sub {
		my($net,$act) = @_;
		my $pm = '';
		my $mode = '';
		my @out;
		for my $ltxt (@{$act->{mode}}) {
			my($d,$txt) = $ltxt =~ /^([-+])(.+)/;
			my $um = $txt2umode[$$net]{$txt};
			if (ref $um) {
				push @out, $um->($net, $act->{dst}, $ltxt);
			} else {
				$mode .= $d if $pm ne $d;
				$mode .= $um;
				$pm = $d;
			}
		}
		push @out, $net->cmd2($act->{dst}, MODE => $act->{dst}, $mode) if $mode;
		@out;
	}, QUIT => sub {
		my($net,$act) = @_;
		return () if $act->{netsplit_quit};
		return () unless $act->{dst}->is_on($net);
		$net->cmd2($act->{dst}, QUIT => $act->{msg});
	}, JOIN => sub {
		my($net,$act) = @_;
		my $chan = $act->{dst};
		if ($act->{src}->homenet()->id() eq $net->id()) {
			print "ERR: Trying to force channel join remotely (".$act->{src}->gid().$chan->str($net).")\n";
			return ();
		}
		my $mode = '';
		if ($act->{mode}) {
			$mode .= $txt2pfx[$$net]{$_} for keys %{$act->{mode}};
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
		my $dst = $act->{dst};
		my @interp = $net->_mode_interp($act->{mode}, $act->{args});
		return () unless @interp;
		return () if @interp == 1 && $interp[0] =~ /^[+-]+$/;
		return $net->cmd2($src, FMODE => $dst, $dst->ts(), @interp);
	}, TOPIC => sub {
		my($net,$act) = @_;
		if ($act->{in_burst}) {
			return $net->ncmd(FTOPIC => $act->{dst}, $act->{topicts}, $act->{topicset}, $act->{topic});
		}
		return $net->cmd2($act->{src}, TOPIC => $act->{dst}, $act->{topic});
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
			my $len = $net->nicklen() - 9;
			my $type = substr $act->{value}, 0, $len;
			$type .= ' (remote)';
			$type =~ s/ /_/g;
			return $net->cmd2($act->{dst}, OPERTYPE => $type);
		}
		return ();
	}, TIMESYNC => sub {
		my($net,$act) = @_;
		my $chan = $act->{dst};
		if ($act->{wipe}) {
			if ($act->{ts} == $act->{oldts}) {
				return $net->ncmd(REMSTATUS => $chan);
			} else {
				return $net->ncmd(FMODE => $chan, $act->{ts}, '+');
			}
		} else {
			my @interp = $net->_mode_interp($chan->mode_delta());
			# delta from channel to undef == remove all modes. We want to add.
			$interp[0] =~ tr/-+/+-/ unless $interp[0] eq '+';
			return $net->ncmd(FMODE => $chan, $act->{ts}, @interp);
		}
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
		} else {
			return () unless $act->{dst}->isa('Nick');
			my $msg = $net->cmd2($act->{src}, $type, $dst, ref $act->{msg} eq 'ARRAY' ? @{$act->{msg}} : $act->{msg});
			return $net->ncmd(PUSH => $act->{dst}, $msg);
		}
	}, WHOIS => sub {
		my($net,$act) = @_;
		$net->cmd2($act->{src}, IDLE => $act->{dst});
	}, PING => sub {
		my($net,$act) = @_;
		$net->ncmd(PING => $net->cparam('linkto'));
	}, LINKREQ => sub {
		my($net,$act) = @_;
		my $src = $act->{net};
		$net->ncmd(OPERNOTICE => $src->netname()." would like to link $act->{slink} to $act->{dlink}");
	}, RAW => sub {
		my($net,$act) = @_;
		$act->{msg};	
	}
}

});

$moddef{'m_ssl_gnutls.so'} = $moddef{'m_ssl_dummy.so'};
$moddef{'m_ssl_openssl.so'} = $moddef{'m_ssl_dummy.so'};

1;
