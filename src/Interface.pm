# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Interface;
use Janus;
use Network;
use Nick;
use Persist 'Network';
use strict;
use warnings;

our $janus; # Janus interface bot: this module handles interactions with this bot

sub pmsg {
	my $act = shift;
	my $src = $act->{src};
	my $dst = $act->{dst};
	my $type = $act->{msgtype};
	return 1 unless ref $src && ref $dst;

	if ($type eq '312') {
		# server whois reply message
		my $nick = $act->{msg}->[0];
		if ($src->isa('Network') && ref $nick && $nick->isa('Nick')) {
			return undef if $src->jlink();
			&Janus::append(+{
				type => 'MSG',
				msgtype => 640,
				src => $src,
				dst => $dst,
				msg => [
					$nick,
					'is connected through a Janus link. Home network: '.$src->netname().
					'; Home nick: '.$nick->homenick(),
				],
			});
		} else {
			warn "Incorrect /whois reply: $src $nick";
		}
		return undef;
	} elsif ($type eq '313') {
		# remote oper - change message type
		$act->{msgtype} = 641;
		$act->{msg}->[-1] .= ' (on remote network)';
		return 0;
	}
	return 1 if $type eq '310'; # available for help

	return undef unless $src->isa('Nick') && $dst->isa('Nick');
	if ($$dst == 1) {
		if ($act->{msg} =~ /^@(\S+)\s*/) {
			my $rto = $Janus::ijnets{$1};
			if ($rto) {
				$act->{sendto} = $rto;
			} else {
				delete $act->{sendto};
			}
		}
		return 0;
	}

	unless ($src->is_on($dst->homenet())) {
		&Janus::jmsg($src, 'You must join a shared channel to speak with remote users') if $act->{msgtype} eq 'PRIVMSG';
		return 1;
	}
	undef;
}

&Janus::hook_add(
	'INIT' => act => sub {
		my $int = Interface->new(
			id => 'janus',
			gid => 'janus',
		);
		$int->_set_netname('Janus');
		&Janus::append(+{
			type => 'NETLINK',
			net => $int,
		});

		my $inick = $Conffile::netconf{set}{janus_nick} || 'janus';

		$janus = Nick->new(
			net => $int,
			nick => $inick,
			ts => ($^T - 1000000000),
			info => {
				ident => ($Conffile::netconf{set}{janus_ident} || 'janus'),
				host => ($Conffile::netconf{set}{janus_rhost} || 'services.janus'),
				vhost => ($Conffile::netconf{set}{janus_host} || 'service'),
				name => 'Janus Control Interface',
				opertype => 'Janus Service',
			},
			mode => { oper => 1, service => 1, bot => 1 },
		);
		warn if $$janus != 1;
		&Janus::append(+{
			type => 'NEWNICK',
			dst => $janus,
		});
	}, MSG => parse => sub {
		my $act = shift;
		my $src = $act->{src};
		my $dst = $act->{dst};
		my $type = $act->{msgtype};
		return 1 unless ref $src && ref $dst;
		return undef unless $src->isa('Nick') && $dst->isa('Nick');
		if ($dst->info('_is_janus')) {
			return 1 unless $act->{msgtype} eq 'PRIVMSG' && $src;
			local $_ = $act->{msg};
			my $cmd = s/^\s*(\S+)\s*// ? lc $1 : 'unk';
			&Janus::in_command($cmd, $src, $_);
			return 1;
		}
		
		undef;
	}, KILL => act => sub {
		my $act = shift;
		return unless $act->{dst} eq $janus;
		&Janus::append(+{
			type => 'CONNECT',
			dst => $act->{dst},
			net => $act->{net},
		});
	}, CHATOPS => jparse => sub {
		my $act = shift;
		delete $act->{IJ_RAW};
		if ($act->{src} == $janus) {
			$act->{msg} = '['.$act->{except}->id().'] '.$act->{msg};
		}
		undef;
	},
);

sub parse { () }
sub send {
	my $net = shift;
	for my $act (@_) {
		if ($act->{type} eq 'MSG' && $act->{msgtype} eq 'PRIVMSG' && $act->{dst} == $janus) {
			my $src = $act->{src} or next;
			$_ = $act->{msg};
			my $cmd = s/^\s*(?:@\S+\s+)?([^@ ]\S*)\s*// ? lc $1 : 'unk';
			&Janus::in_command($cmd, $src, $_);
		}
	}
}
sub request_newnick { $_[2] }
sub request_cnick { $_[2] }
sub release_nick { }
sub is_synced { 0 }
sub all_nicks { $janus }
sub all_chans { () }

1;
