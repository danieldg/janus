# Copyright (C) 2007-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Server::InspMods;
use Carp;
use strict;
use warnings;

sub ignore { () }

our %modules = ();
&Janus::static('modules');

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

&Event::hook_add(
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

mdef 'm_alias.so';
mdef 'm_alltime.so', cmds => {
	ALLTIME => sub {
		my $net = shift;
		my $nick = $net->mynick($_[0]) or return ();
		return +{
			type => 'TSREPORT',
			src => $nick,
			sendto => $Janus::global,
		};
	},
}, acts => {
	TSREPORT => sub {
		my($net,$act) = @_;
		return () unless $act->{src}->is_on($net);
		$net->cmd2($act->{src}, 'ALLTIME');
	},
};

mdef 12, 'm_allowinvite.so', cmode => { A => 'r_allinvite' };
mdef 'm_antibear.so';
mdef 'm_antibottler.so';

# This can be set in config to hide ops too, see
# http://www.inspircd.org/wiki/Modules/auditorium
mdef 'm_auditorium.so', cmode => { u => 'r_auditorium' };
mdef 'm_banexception.so', cmode => { e => 'l_except' };
mdef 'm_banredirect.so'; # this just adds syntax to channel bans
mdef 'm_blockamsg.so';
mdef 1105, 'm_blockcaps.so', cmode => { P => 'r_blockcaps' };
mdef 12, 'm_blockcaps.so', cmode => { B => 'r_blockcaps' };
mdef 'm_blockcolor.so', cmode => { c => 't2_colorblock' };
mdef 'm_botmode.so', umode => { B => 'bot' };

mdef 12, 'm_callerid.so', umode => { g => 'callerid' }, cmds => { ACCEPT => \&ignore };
mdef 'm_cban.so', cmds => { CBAN => \&ignore }; # janus needs localjoin to link, so we don't care
mdef 'm_censor.so', cmode => { G => 'r_badword' }, umode => { G => 'badword' };
mdef 'm_hidechans.so', umode => { I => 'hide_chans' };
mdef 'm_cgiirc.so';
mdef 'm_chancreate.so';
mdef 'm_chanlog.so';
mdef 'm_chanfilter.so', cmode => { g => 'l_badwords' };
mdef 'm_chanprotect.so', cmode => { a => 'n_admin', 'q' => 'n_owner' };
mdef 'm_check.so';
	
mdef 'm_chghost.so', cmds => {
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
mdef 'm_chgident.so', cmds => {
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
			return $net->cmd2($Interface::janus, CHGIDENT => $act->{dst}, $act->{value});
		}
		();
	},
};
mdef 'm_chgname.so', cmds => {
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

mdef 'm_cloaking.so', umode => { x => '' };
mdef 'm_clones.so';
mdef 'm_close.so';
mdef 'm_conn_join.so';
mdef 'm_conn_umodes.so';
mdef 'm_conn_waitpong.so';
mdef 'm_connflood.so';
mdef 'm_commonchans.so', umode => { c => 'deaf_commonchan' };
mdef 'm_customtitle.so';
mdef 'm_cycle.so';
mdef 'm_dccallow.so', cmds => { DCCALLOW => \&ignore };
mdef 'm_deaf.so', umode => { d => 'deaf_chan' };
mdef 12, 'm_delayjoin.so', cmode => { D => 'r_delayjoin' };
mdef 'm_denychans.so';
mdef 'm_devoice.so', cmds => {
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
mdef 'm_filter.so', cmds => { FILTER => \&ignore };
mdef 'm_filter_pcre.so', cmds => { FILTER => \&ignore };
mdef 'm_foobar.so';
# hack: G(UN)LOADMODULE cmds are in core so that m_globalload can be
# loaded and used without needing to split janus
mdef 'm_globalload.so', cmds => { GRELOADMODULE => \&ignore };
mdef 'm_globops.so',
	cmds => { GLOBOPS => \&ignore };
mdef 'm_helpop.so', umode => { h => 'helpop' }, cmds => { HELPOP => \&ignore };
mdef 'm_hideoper.so', umode => { H => 'hideoper' };
mdef 'm_hostchange.so';
mdef 'm_http_client.so';
mdef 'm_httpd.so';
mdef 'm_httpd_stats.so';
mdef 'm_ident.so';

# sadly, you are NOT invisible to remote users :P
mdef 'm_invisible.so', umode => { Q => 'hiddenabusiveoper' };
mdef 'm_inviteexception.so', cmode => { I => 'l_invex' };

mdef 'm_janus.so', acts => {
	'CONNECT+' => sub {
		my($net,$act) = @_;
		my $nick = $act->{dst};
		return $net->ncmd(METADATA => $nick, 'jinfo', 'Home network: '.
			$nick->homenet()->netname().'; Home nick: '.$nick->homenick());
	},
	'NICK+' => sub {
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
mdef 'm_namesx.so';
mdef 'm_nickflood.so', cmode => { F => 's_nickflood' };
mdef 1105, 'm_nicklock.so', cmds => {
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
mdef 12, 'm_nicklock.so', cmds => {
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
mdef 'm_nonicks.so', cmode => { N => 'r_norenick' };
mdef 'm_nonotice.so', cmode => { T => 'r_noticeblock' };
mdef 'm_oper_hash.so';
mdef 'm_operchans.so', cmode => { O => 'r_oper' };
mdef 'm_operjoin.so';
mdef 'm_operlevels.so';
mdef 'm_operlog.so';
mdef 'm_opermodes.so';
mdef 'm_opermotd.so';
mdef 'm_override.so';
mdef 12, 'm_permchannels.so', cmode => { P => 'r_permanent' };
mdef 'm_randquote.so';
mdef 'm_redirect.so', cmode => { L => 's_forward' };
mdef 'm_regonlycreate.so';
mdef 'm_remove.so', cmds => {
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
mdef 'm_restrictbanned.so';
mdef 'm_restrictchans.so';
mdef 'm_restrictmsg.so';
mdef 'm_safelist.so';
mdef 'm_sajoin.so', cmds => { 'SAJOIN' => \&ignore };
mdef 'm_samode.so';
mdef 1105, 'm_sanick.so', cmds => {
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
mdef 12, 'm_sanick.so', cmds => {
	SANICK => sub {
		my $net = shift;
		my $nick = $net->nick($_[2]) or return ();
		if ($nick->homenet() == $net) {
			# BUG: this is misrouted, the NICK is already sent or will be soon
			return ();
		}
		# sorry, you did not change my nick
		$net->send($net->cmd2($nick, NICK => $nick->str($net), $nick->ts));
		();
	},
};
mdef 'm_sapart.so', cmds => { 'SAPART' => \&ignore };
mdef 1105, 'm_saquit.so', cmds => { 'SAQUIT' => 'KILL' };
mdef 12, 'm_saquit.so', cmds => { 'SAQUIT' => \&ignore };
mdef 'm_securelist.so';
mdef 'm_seenicks.so';
mdef 1105, 'm_services.so', cmode => {
	r => 'r_',
	R => 'r_reginvite',
	M => 'r_regmoderated'
}, umode => {
	r => 'registered',
	R => 'deaf_regpriv'
}, umode_hook => {
	registered => sub { '' },
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
			}, +{
				type => 'UMODE',
				dst => $nick,
				mode => [ $_[4] eq '' ? '-registered' : '+registered' ],
			};
		},
	};

mdef 12, 'm_services_account.so', cmode => {
	r => 'r_',
	R => 'r_reginvite',
	M => 'r_regmoderated',
}, umode => {
	r => 'registered',
	R => 'deaf_regpriv',
}, umode_hook => {
	registered => sub { '' },
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

mdef 'm_sethost.so', cmds => {
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
mdef 'm_setident.so', cmds => {
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
mdef 'm_setname.so', cmds => {
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
mdef 'm_shun.so', cmds => { SHUN => \&ignore };
mdef 'm_showwhois.so', umode => { W => 'whois_notice' }, acts => {
	WHOIS => sub {
		my($net,$act) = @_;
		my($src,$dst) = @$act{'src','dst'};
		return () unless $dst->isa('Nick') && $dst->has_mode('whois_notice');
		$net->ncmd(PUSH => $dst, $net->cmd2($src->homenet()->jname(), NOTICE =>
			$dst, '*** '.$src->str($net).' did a /whois on you.'));
	},
};
mdef 'm_silence.so', cmds => { SILENCE => \&ignore };
mdef 'm_silence_ext.so', cmds => { SILENCE => \&ignore };
mdef 'm_spanningtree.so';
mdef 'm_spy.so';
mdef 'm_sslmodes.so', cmode => { z => 'r_sslonly' };
mdef 'm_ssl_dummy.so', metadata => {
	ssl => sub {
		my $net = shift;
		my $nick = $net->mynick($_[2]) or return ();
		&Log::warn_in($net, "Unknown SSL value $_[4]") unless $_[4] eq 'ON';
		return +{
			type => 'UMODE',
			dst => $nick,
			mode => [ '+ssl' ],
		};
	},
}, umode_hook => {
	ssl => sub {
		my($net, $nick, $pm, $out) = @_;
		if ($pm eq '+ssl') {
			push @$out, $net->ncmd(METADATA => $nick, ssl => 'ON');
		} else {
			&Log::warn('Inspircd is incapable of unsetting SSL');
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
}, cmds => {
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
}, acts => {
	NICKINFO => sub {
		my($net,$act) = @_;
		if ($act->{item} eq 'swhois') {
			return $net->ncmd(METADATA => $act->{dst}, 'swhois', $act->{value});
		}
		()
	},
};
mdef 'm_taxonomy.so';
mdef 'm_testcommand.so';
mdef 'm_timedbans.so', cmds => { TBAN => \&ignore };
mdef 'm_tline.so';
mdef 'm_uhnames.so';
mdef 'm_uninvite.so';
mdef 'm_userip.so';
mdef 'm_vhost.so'; # routed as normal FHOST
mdef 'm_watch.so';
mdef 'm_xmlsocket.so';

1;
