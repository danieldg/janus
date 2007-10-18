# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Server::InspMods;
use LocalNetwork;
use Persist 'LocalNetwork';
use strict;
use warnings;

our($VERSION) = '$Rev$' =~ /(\d+)/;

sub ignore { () }

our %modules = (
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
		cmode => { c => 't2_colorblock' },
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
					return $net->cmd2($Janus::interface, CHGIDENT => $act->{dst}, $act->{value});
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
	'm_close.so' => { },
	'm_conn_join.so' => { },
	'm_conn_umodes.so' => { },
	'm_conn_waitpong.so' => { },
	'm_connflood.so' => { },
	'm_customtitle.so' => { },
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
	'm_filter_pcre.so' => { cmds => { FILTER => \&ignore } },
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
		acts => { CHATOPS => sub {
			my($net,$act) = @_;
			$net->cmd2($act->{src}, GLOBOPS => $act->{msg});
		} }
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
	'm_nickflood.so' => {
		cmode => { F => 's_nickflood' },
	},
	'm_nicklock.so' => {
		cmds => {
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
						nickts => time,
					};
				}
				# we need to unlock and change nicks back
				my @out;
				push @out, $net->cmd2($Janus::interface, NICKUNLOCK => $_[3]);
				push @out, $net->cmd2($_[3], NICK => $_[2]) unless $_[2] eq $_[3];
				$net->send(@out);
				();
			},
			NICKUNLOCK => \&ignore,
		},
	},
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
				if ($nick->homenet() eq $net) {
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
		cmode => { S => 't1_colorblock' }
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
);

$modules{'m_ssl_gnutls.so'} = $modules{'m_ssl_dummy.so'};
$modules{'m_ssl_openssl.so'} = $modules{'m_ssl_dummy.so'};

1;
