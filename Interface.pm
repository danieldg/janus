# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Interface;
use Janus;
use Network;
use Nick;
use Persist 'Network';
use strict;
use warnings;
our($VERSION) = '$Rev$' =~ /(\d+)/;

my $inick = $Conffile::netconf{janus}{janus} || 'janus';

if ($Janus::interface) {
	# we are being live-reloaded as a module. Don't recreate
	# the network or nick, just reload commands
	print "Reloading Interface\n";
	if ($inick ne $Janus::interface->homenick()) {
		&Janus::insert_full(+{
			type => 'NICK',
			dst => $Janus::interface,
			nick => $inick,
			nickts => 100000000,
		});
	}
} else {
	my $int = Interface->new(
		id => 'janus',
	);
	$int->_set_netname('Janus');
	&Janus::insert_full(+{
		type => 'NETLINK',
		net => $int,
		sendto => [],
	});

	$Janus::interface = Nick->new(
		net => $int,
		nick => $inick,
		ts => 100000000,
		info => {
			ident => 'janus',
			host => 'services.janus',
			vhost => 'services',
			name => 'Janus Control Interface',
			opertype => 'Janus Service',
			_is_janus => 1,
		},
		mode => { oper => 1, service => 1, bot => 1 },
	);
	&Janus::insert_full(+{
		type => 'NEWNICK',
		dst => $Janus::interface,
	});
}

&Janus::hook_add(
	BURST => act => sub {
		my $act = shift;
		my $net = $act->{net};
		return if $net->jlink();
		&Janus::append(+{
			type => 'CONNECT',
			dst => $Janus::interface,
			net => $net,
		});
	}, KILL => act => sub {
		my $act = shift;
		return unless $act->{dst} eq $Janus::interface;
		&Janus::append(+{
			type => 'CONNECT',
			dst => $act->{dst},
			net => $act->{net},
		});
	}, NETSPLIT => act => sub {
		my $act = shift;
		$Janus::interface->_netpart($act->{net});
	}, MSG => parse => sub {
		my $act = shift;
		my $src = $act->{src};
		my $dst = $act->{dst};
		my $type = $act->{msgtype};
		return 1 unless ref $src && ref $dst;

		if ($type eq '312') {
			# server whois reply message
			my $nick = $act->{msg}->[0];
			if ($src->isa('Network') && ref $nick && $nick->isa('Nick')) {
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
		if ($dst->info('_is_janus')) {
			return 1 unless $act->{msgtype} eq 'PRIVMSG' && $src;
			local $_ = $act->{msg};
			my $cmd = s/^\s*(\S+)\s*// ? lc $1 : 'unk';
			&Janus::in_command($cmd, $src, $_);
			return 1;
		}
		
		unless ($src->is_on($dst->homenet())) {
			&Janus::jmsg($src, 'You must join a shared channel to speak with remote users') if $act->{msgtype} eq 'PRIVMSG';
			return 1;
		}
		undef;
	}, WHOIS => parse => sub {
		my $act = shift;
		my $src = $act->{src};
		my $dst = $act->{dst};
		unless ($src->is_on($dst->homenet())) {
			&Janus::jmsg($src, 'You cannot use this /whois syntax unless you are on a shared channel with the user');
			return 1;
		}
		undef;
	}, LINKREQ => act => sub {
		my $act = shift;
		my $snet = $act->{net};
		my $dnet = $act->{dst};
		print "Link request:";
		if ($dnet->jlink() || $dnet->isa('Interface')) {
			print " dst non-local";
		} else {
			my $recip = $dnet->is_req($act->{dlink}, $snet);
			print $recip ? " dst req:$recip" : " dst new req";
			$recip = 'any' if $recip && $act->{override};
			if ($act->{linkfile}) {
				if ($dnet->is_synced()) {
					print '; linkfile: override';
					$recip = 'any';
				} else {
					$recip = '';
					print '; linkfile: not synced';
				}
			}
			if ($recip && ($recip eq 'any' || lc $recip eq lc $act->{slink})) {
				print " => LINK OK!\n";
				# there has already been a request to link this channel to that network
				# also, if it was not an override, the request was for this pair of channels
				$dnet->del_req($act->{dlink}, $snet);
				&Janus::append(+{
					type => 'LSYNC',
					src => $dnet,
					dst => $snet,
					chan => $dnet->chan($act->{dlink},1),
					linkto => $act->{slink},
					linkfile => $act->{linkfile},
				});
				# do not add it to request list now
				return;
			}
		}
		if ($snet->jlink()) {
			print "; src non-local\n";
		} else {
			$snet->add_req($act->{slink}, $dnet, $act->{dlink});
			print "; added to src requests\n";
		}
	},
);

sub parse { () }
sub send { }
sub request_newnick { $_[2] }
sub request_cnick { $_[2] }
sub release_nick { }
sub is_synced { 0 }
sub add_req { }
sub del_req { }
sub is_req { 'invalid' }
sub all_nicks { $Janus::interface }
sub all_chans { () }

1;
