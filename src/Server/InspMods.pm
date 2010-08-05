# Copyright (C) 2007-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Server::InspMods;
use Carp;
use strict;
use warnings;

sub ignore { () }

our %modules = ();
Janus::static('modules');

sub mdef {
	my $name = shift;
	my @ver;
	until ($name =~ /^m_/) {
		push @ver, $name;
		$name = shift;
	}
	@ver = qw/1105 1200 1201/ unless @ver;
	@ver = map { $_ eq '12' ? qw/1200 1201/ : $_ } @ver;
	if (@_ % 2) {
		warn 'Odd argument count';
	}
	my %args = @_;
	if ($modules{$name} && $modules{$name}{for}) {
		my $old = $modules{$name};
		my $for = delete $old->{for};
		$modules{$name} = {};
		$modules{$name}{$_} = $old for split / /, $for;
	}
	if ($modules{$name}) {
		for (@ver) {
			warn "Module $name (for $_) redefined" if $modules{$name}{$_};
			$modules{$name}{$_} = \%args;
		}
	} else {
		$args{for} = join ' ', @ver;
		$modules{$name} = \%args;
	}
}

Event::hook_add(
	Server => find_module => sub {
		my($net, $name, $d) = @_;
		return if ref($net) !~ /Server::Inspircd/;
		my $ver = $net->protoctl;
		return unless $modules{$name};
		if ($modules{$name}{for}) {
			return unless grep { $ver == $_ } split / /, $modules{$name}{for};
			$$d = $modules{$name};
		} else {
			return unless $modules{$name}{$ver};
			$$d = $modules{$name}{$ver};
		}
	},
);
mdef 1201, 'm_abbreviation.so';
mdef 'm_alias.so';
mdef 12, 'm_allowinvite.so', cmode => { A => 'r_allinvite' };
mdef 'm_alltime.so', parse => {
	ALLTIME => sub {
		my $net = shift;
		my $nick = $net->mynick($_[0]) or return ();
		return +{
			type => 'TSREPORT',
			src => $nick,
			sendto => $Janus::global,
		};
	},
}, 'send' => {
	TSREPORT => sub {
		my($net,$act) = @_;
		return () unless $act->{src}->is_on($net);
		$net->cmd2($act->{src}, 'ALLTIME');
	},
};
mdef 'm_antibear.so';
mdef 'm_antibottler.so';

mdef 'm_auditorium.so', cmode => { u => 'r_auditorium' };
mdef 1201, 'm_autoop.so', cmode => { w=> 'r_autoop ' };
mdef 'm_banexception.so',
	cmode_in => {
		'e' => sub {
			my($net, $di, $ci, $ai, $mo, $ao, $do) = @_;
			my $ban = shift @$ai;
			if ($ban =~ /^(.):(.*)/) {
				my $expr = $2;
				my @hook = $net->hook(cm_extban => $1);
				$_->($net, $di, $ci, $expr, 'ex', $mo, $ao, $do) for @hook;
				return if @hook;
			}
			push @$mo, 'except';
			push @$ao, $ban;
			push @$do, $di;
		},
	}, cmode_out => {
		except => sub {
			('e', $_[3]);
		},
	};

mdef 'm_banredirect.so'; # this just adds syntax to channel bans
mdef 'm_blockamsg.so';
mdef 1105, 'm_blockcaps.so', cmode => { P => 'r_blockcaps' };
mdef 12, 'm_blockcaps.so', cmode => { B => 'r_blockcaps' };
mdef 'm_blockcolor.so', cmode => { c => 't2_colorblock' };
mdef 'm_botmode.so', umode => { B => 'bot' };

mdef 12, 'm_callerid.so', umode => { g => 'callerid' }, parse => { ACCEPT => \&ignore };
mdef 'm_cban.so', parse => { CBAN => \&ignore }; # janus needs localjoin to link, so we don't care
mdef 'm_censor.so', cmode => { G => 'r_badword' }, umode => { G => 'badword' };
mdef 'm_cgiirc.so';
mdef 'm_chancreate.so';
mdef 1201, 'm_chanhistory.so', umode => { H => 's_chanhistory'};
mdef 'm_chanlog.so';
mdef 'm_chanfilter.so', cmode => { g => 'l_badwords' };
mdef 'm_channelban.so';
mdef 'm_chanprotect.so', cmode => { a => 'n_admin', 'q' => 'n_owner' };
mdef 'm_check.so';

mdef 'm_chghost.so', parse => {
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
};
mdef 'm_chgident.so', parse => {
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
}, 'send' => {
	NICKINFO => sub {
		my($net,$act) = @_;
		if ($act->{item} eq 'ident') {
			return $net->cmd2($Interface::janus, CHGIDENT => $act->{dst}, $act->{value});
		}
		();
	},
};
mdef 'm_chgname.so', parse => {
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
};

mdef 'm_cloaking.so';
mdef 'm_clones.so';
mdef 'm_close.so';
mdef 'm_conn_join.so';
mdef 'm_conn_umodes.so';
mdef 'm_conn_waitpong.so';
mdef 'm_connflood.so';
mdef 'm_commonchans.so', umode => { c => 'deaf_commonchan' };
mdef 'm_customtitle.so', metadata => {
	ctitle => sub {
		my $net = shift;
		my $nick = $net->mynick($_[2]) or return ();
		return +{
			type => 'NICKINFO',
			src => $net->item($_[0]),
			dst => $nick,
			item => 'ctitle',
			value => $_[4],
		};
	},
}, 'send' => {
	NICKINFO => sub {
		my($net,$act) = @_;
		if ($act->{item} eq 'ctitle') {
			return $net->ncmd(METADATA => $act->{dst}, 'ctitle', $act->{value});
		}
		()
	},
};
mdef 'm_cycle.so';
mdef 'm_dccallow.so', parse => { DCCALLOW => \&ignore };
mdef 'm_deaf.so', umode => { d => 'deaf_chan' };
mdef 12, 'm_delayjoin.so', cmode => { D => 'r_delayjoin' };
mdef 1201, 'm_delaymsg.so', cmode => { d => 'r_delaymsg' };
mdef 'm_denychans.so';
mdef 'm_devoice.so', parse => {
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
};
mdef 'm_dnsbl.so';
mdef 'm_filter.so', parse => { FILTER => \&ignore };
mdef 'm_filter_pcre.so', parse => { FILTER => \&ignore };
mdef 'm_foobar.so';
mdef 'm_gecosban.so', cm_extban => {
	'r' => sub {
		my($net, $di, $ci, $ai, $ti, $mo, $ao, $do) = @_;
		push @$mo, 'gecos_'.$ti;
		push @$ao, $ai;
		push @$do, $di;
	},
}, cmode_out => {
	gecos_ban => sub {
		('b', 'r:'.$_[3]);
	},
	gecos_ex => sub {
		return () unless $_[0]->get_module('m_banexception.so');
		('e', 'r:'.$_[3]);
	},
	gecos_inv => sub {
		return () unless $_[0]->get_module('m_inviteexception.so');
		('I', 'r:'.$_[3]);
	},
};

# hack: G(UN)LOADMODULE cmds are in core so that m_globalload can be
# loaded and used without needing to split janus
mdef 1201, 'm_geoip.so';
mdef 'm_globalload.so', parse => { GRELOADMODULE => \&ignore };
mdef 'm_globops.so',
	parse => { GLOBOPS => \&ignore };
mdef 1201, 'm_halfop.so', cmode => { h => 'n_halfop' };
mdef 'm_helpop.so', umode => { h => 'helpop' }, parse => { HELPOP => \&ignore };
mdef 'm_hidechans.so', umode => { I => 'hide_chans' };
mdef 'm_hideoper.so', umode => { H => 'hideoper' };
mdef 'm_hostchange.so';
mdef 'm_http_client.so';
mdef 'm_httpd.so';
mdef 'm_httpd_stats.so';
mdef 'm_ident.so';

mdef 'm_invisible.so';
mdef 'm_inviteexception.so',
	cmode_in => {
		'I' => sub {
			my($net, $di, $ci, $ai, $mo, $ao, $do) = @_;
			my $ban = shift @$ai;
			if ($ban =~ /^(.):(.*)/) {
				my $expr = $2;
				my @hook = $net->hook(cm_extban => $1);
				$_->($net, $di, $ci, $expr, 'inv', $mo, $ao, $do) for @hook;
				return if @hook;
			}
			push @$mo, 'invex';
			push @$ao, $ban;
			push @$do, $di;
		},
	}, cmode_out => {
		invex => sub {
			('I', $_[3]);
		},
	};

mdef 'm_janus.so', 'send' => {
	'CONNECT' => sub {
		my($net,$act) = @_;
		my $nick = $act->{dst};
		return $net->ncmd(METADATA => $nick, 'jinfo', 'Home network: '.
			$nick->homenet()->netname().'; Home nick: '.$nick->homenick());
	},
	'NICK' => sub {
		my($net,$act) = @_;
		my $nick = $act->{dst};
		return $net->ncmd(METADATA => $nick, 'jinfo', 'Home network: '.
			$nick->homenet()->netname().'; Home nick: '.$act->{nick});
	},
};

mdef 'm_joinflood.so', cmode => { j => 's_joinlimit' };
mdef 'm_jumpserver.so';
mdef 'm_kicknorejoin.so', cmode => { J => 's_kicknorejoin' };
# TODO translate INVITE and KNOCK across janus
mdef 'm_knock.so', cmode => { K => 'r_noknock' };
mdef 'm_lockserv.so';
mdef 'm_md5.so';
mdef 'm_messageflood.so', cmode => { f => 's_flood' };
mdef 'm_muteban.so', cm_extban => {
	'm' => sub {
		my($net, $di, $ci, $ai, $ti, $mo, $ao, $do) = @_;
		return if $ti eq 'inv';
		push @$mo, 'quiet_'.$ti;
		push @$ao, $ai;
		push @$do, $di;
	},
}, cmode_out => {
	quiet_ban => sub {
		('b', 'm:'.$_[3]);
	},
	quiet_ex => sub {
		return () unless $_[0]->get_module('m_banexception.so');
		('e', 'm:'.$_[3]);
	},
};
mdef 'm_namesx.so';
mdef 'm_nationalchars.so';
mdef 'm_nickflood.so', cmode => { F => 's_nickflood' };
mdef 1105, 'm_nicklock.so', parse => {
	NICKLOCK => sub {
		my $net = shift;
		my $nick = $net->nick($_[2]);
		if ($nick->homenet() eq $net) {
			return () if $_[2] eq $_[3];
			# accept it as a nick change
			return +{
				type => 'NICK',
				src => $nick,
				dst => $nick,
				nick => $_[3],
				nickts => $Janus::time,
			};
		}
		# we need to unlock and change nicks back
		my @out;
		push @out, $net->cmd2($Interface::janus, NICKUNLOCK => $_[3]);
		push @out, $net->cmd2($_[3], NICK => $_[2]) unless $_[2] eq $_[3];
		$net->send(@out);
		();
	},
	NICKUNLOCK => \&ignore,
};
mdef 12, 'm_nicklock.so', parse => {
	NICKLOCK => sub {
		my $net = shift;
		my $nick = $net->nick($_[2]);
		my $before = $nick->str($net);
		if ($nick->homenet() eq $net) {
			return () if $before eq $_[3];
			# accept it as a nick change
			return +{
				type => 'NICK',
				src => $nick,
				dst => $nick,
				nick => $_[3],
				nickts => $Janus::time,
			};
		}
		# we need to unlock and change nicks back
		my @out;
		push @out, $net->cmd2($Interface::janus, NICKUNLOCK => $nick);
		push @out, $net->cmd2($nick, NICK => $before) unless $before eq $_[3];
		$net->send(@out);
		();
	},
	NICKUNLOCK => \&ignore,
};

mdef 'm_noctcp.so', cmode => { C => 'r_ctcpblock' };
mdef 'm_noinvite.so', cmode => { V => 'r_noinvite' };
mdef 'm_nokicks.so', cmode => { Q => 'r_nokick' };
mdef 'm_nonicks.so', cmode => { N => 'r_norenick' }, cm_extban => {
	'N' => sub {
		my($net, $di, $ci, $ai, $ti, $mo, $ao, $do) = @_;
		return if $ti eq 'inv';
		push @$mo, 'renick_'.$ti;
		push @$ao, $ai;
		push @$do, $di;
	},
}, cmode_out => {
	renick_ban => sub {
		('b', 'N:'.$_[3]);
	},
	renick_ex => sub {
		return () unless $_[0]->get_module('m_banexception.so');
		('e', 'N:'.$_[3]);
	},
};

mdef 'm_nonotice.so', cmode => { T => 'r_noticeblock' };
mdef 'm_nopartmsg.so';
mdef 'm_oper_hash.so';
mdef 'm_operchans.so', cmode => { O => 'r_oper' };
mdef 'm_operinvex.so';
mdef 'm_operjoin.so';
mdef 'm_operlevels.so';
mdef 'm_operlog.so';
mdef 'm_opermodes.so';
mdef 'm_opermotd.so';
mdef 12, 'm_operprefix.so', cmode => { y => 'n_' };
mdef 'm_override.so';
mdef 12, 'm_permchannels.so', cmode => { P => 'r_permanent' };
mdef 'm_randquote.so';
mdef 'm_redirect.so', cmode => { L => 's_forward' };
mdef 'm_regex_glob.so';
mdef 'm_regex_pcre.so';
mdef 'm_regex_posix.so';
mdef 'm_regex_tre.so';
mdef 'm_regonlycreate.so';
mdef 'm_remove.so', parse => {
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
};
mdef 12, 'm_rline.so';
mdef 'm_restrictbanned.so';
mdef 'm_restrictchans.so';
mdef 'm_restrictmsg.so';
mdef 'm_safelist.so';
mdef 'm_sajoin.so', parse => { 'SAJOIN' => \&ignore };
mdef 'm_samode.so';
mdef 1105, 'm_sanick.so', parse => {
	SANICK => sub {
		my $net = shift;
		my $nick = $net->nick($_[2]) or return ();
		if ($nick->homenet() == $net) {
			# BUG: this is misrouted, the NICK is already sent or will be soon
			return ();
		}
		# reject
		$net->send($net->cmd2($_[3], NICK => $_[2]));
		();
	},
};
mdef 12, 'm_sanick.so', parse => {
	SANICK => sub {
		my $net = shift;
		my $nick = $net->nick($_[2]) or return ();
		if ($nick->homenet() == $net) {
			# BUG: this is misrouted, the NICK is already sent or will be soon
			return ();
		}
		# sorry, you did not change my nick
		$net->send($net->cmd2($nick, NICK => $nick->str($net), $nick->ts($net)));
		();
	},
};
mdef 'm_sapart.so', parse => { 'SAPART' => \&ignore };
mdef 1105, 'm_saquit.so', parse => { 'SAQUIT' => 'KILL' };
mdef 12, 'm_saquit.so', parse => { 'SAQUIT' => \&ignore };
mdef 'm_securelist.so';
mdef 'm_seenicks.so';
mdef 'm_serverban.so';
mdef 1105, 'm_services.so', cmode => {
	R => 'r_reginvite',
	M => 'r_regmoderated'
}, umode => {
	R => 'deaf_regpriv',
};
mdef 1105, 'm_services_account.so', cmode => { R => 'r_reginvite', M => 'r_regmoderated' },
	umode => { R => 'deaf_regpriv' },
	metadata => {
		accountname => sub {
			my $net = shift;
			my $nick = $net->mynick($_[2]) or return ();
			return +{
				type => 'NICKINFO',
				dst => $nick,
				item => 'svsaccount',
				value => $_[4],
			};
		},
	};

mdef 12, 'm_services_account.so', cmode => {
	R => 'r_reginvite',
	M => 'r_regmoderated',
}, umode => {
	R => 'deaf_regpriv',
}, metadata => {
	accountname => sub {
		my $net = shift;
		my $nick = $net->mynick($_[2]) or return ();
		return +{
			type => 'NICKINFO',
			dst => $nick,
			item => 'svsaccount',
			value => $_[4],
		};
	},
};

mdef 12, 'm_servprotect.so', umode => { k => 'service' };

mdef 'm_sethost.so', parse => {
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
};
mdef 'm_setident.so', parse => {
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
};
mdef 'm_setname.so', parse => {
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
};
mdef 'm_setidle.so';
mdef 'm_sha256.so';
mdef 'm_showwhois.so', umode => { W => 'whois_notice' }, 'send' => {
	WHOIS => sub {
		my($net,$act) = @_;
		my($src,$dst) = @$act{'src','dst'};
		return () unless $dst->isa('Nick') && $dst->has_mode('whois_notice');
		$net->ncmd(PUSH => $dst, $net->cmd2($src->homenet()->jname(), NOTICE =>
			$dst, '*** '.$src->str($net).' did a /whois on you.'));
	},
};
mdef 'm_shun.so', parse => { SHUN => \&ignore };
mdef 'm_silence.so', parse => { SILENCE => \&ignore };
mdef 'm_silence_ext.so', parse => { SILENCE => \&ignore };
mdef 'm_spanningtree.so';
mdef 'm_spy.so';
mdef 'm_sslmodes.so', cmode => { z => 'r_sslonly' };
mdef 'm_ssl_dummy.so', metadata => {
	ssl => sub {
		my $net = shift;
		my $nick = $net->mynick($_[2]) or return ();
		Log::warn_in($net, "Unknown SSL value $_[4]") unless uc $_[4] eq 'ON';
		return +{
			type => 'UMODE',
			dst => $nick,
			mode => [ '+ssl' ],
		};
	},
}, umode_out => {
	ssl => sub {
		my($net, $pm, $nick, $out) = @_;
		if ($pm eq '+') {
			push @$out, $net->ncmd(METADATA => $nick, ssl => 'ON');
		} else {
			Log::warn('Inspircd is incapable of unsetting SSL');
		}
		'';
	},
};

$modules{$_} = $modules{'m_ssl_dummy.so'} for qw/m_ssl_gnutls.so m_ssl_openssl.so/;

mdef 'm_stripcolor.so', umode => { S => 'colorstrip' }, cmode => { S => 't1_colorblock' };
mdef 'm_svshold.so';
mdef 'm_swhois.so', metadata => {
	swhois => sub {
		my $net = shift;
		my $nick = $net->mynick($_[2]) or return ();
		return +{
			type => 'NICKINFO',
			src => $net->item($_[0]),
			dst => $nick,
			item => 'swhois',
			value => $_[4],
		};
	},
}, parse => {
	SWHOIS => sub {
		my $net = shift;
		my $nick = $net->mynick($_[2]) or return ();
		return +{
			type => 'NICKINFO',
			src => $net->item($_[0]),
			dst => $nick,
			item => 'swhois',
			value => $_[3],
		};
	},
}, 'send' => {
	NICKINFO => sub {
		my($net,$act) = @_;
		if ($act->{item} eq 'swhois') {
			return $net->ncmd(METADATA => $act->{dst}, swhois => $act->{value});
		}
		()
	},
};
mdef 'm_taxonomy.so';
mdef 'm_testcommand.so';
mdef 'm_timedbans.so', parse => { TBAN => \&ignore };
mdef 'm_tline.so';
mdef 'm_uhnames.so';
mdef 'm_uninvite.so', parse => { UNINVITE => \&ignore };
mdef 'm_userip.so';
mdef 'm_vhost.so'; # routed as normal FHOST
mdef 'm_watch.so', parse => { SVSWATCH => \&ignore };
mdef 'm_xmlsocket.so';

1;
