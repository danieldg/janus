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
		gid => 'janus',
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
	if ($dst->info('_is_janus')) {
		return 1 unless $act->{msgtype} eq 'PRIVMSG' && $src;
		local $_ = $act->{msg};
		if (s/^@(\S+)\s*//) {
			my $rto = $Janus::ijnets{$1};
			if ($rto) {
				$act->{sendto} = [ $rto ];
				return 0;
			} elsif ($1 ne $Janus::name) {
				&Janus::jmsg($src, "Cannot find remote network $1");
				return 1;
			}
		}
		my $cmd = s/^\s*(\S+)\s*// ? lc $1 : 'unk';
		&Janus::in_command($cmd, $src, $_);
		return 1;
	}

	unless ($src->is_on($dst->homenet())) {
		&Janus::jmsg($src, 'You must join a shared channel to speak with remote users') if $act->{msgtype} eq 'PRIVMSG';
		return 1;
	}
	undef;
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
	},
	MSG => parse => \&pmsg,
	MSG => jparse => \&pmsg,
	WHOIS => parse => sub {
		my $act = shift;
		my $src = $act->{src};
		my $dst = $act->{dst};
		return undef if $src->is_on($dst->homenet());
		if ($dst eq $Janus::interface) {
			my $net = $src->homenet();
			my @msgs = (
				[ 311, $src->info('ident'), $src->info('vhost'), '*', $src->info('name') ],
				[ 312, 'janus.janus', "Janus Interface" ],
				[ 319, join ' ', map { $_->is_on($net) ? $_->str($net) : () } $dst->all_chans() ],
				[ 317, 0, 0, 'seconds idle, signon time'], # TODO is the janus start time kept?
				[ 318, 'End of /WHOIS list' ],
			);
			&Janus::append(map +{
				type => 'MSG',
				src => $net,
				dst => $src,
				msgtype => $_->[0], # first part of message
				msg => [$dst, @$_[1 .. $#$_] ], # source nick, rest of message array
			}, @msgs);
		} else {
			&Janus::jmsg($src, 'You cannot use this /whois syntax unless you are on a shared channel with the user');
		}
		return 1;
	}, LINKREQ => act => sub {
		my $act = shift;
		my $snet = $act->{net};
		my $dnet = $act->{dst};
		print "Link request:";
		if ($snet->jlink()) {
			print " src non-local;";
		} else {
			$snet->add_req($act->{slink}, $dnet, $act->{dlink});
			print " added to src requests;";
		}
		if ($dnet->jlink() || $dnet->isa('Interface')) {
			print " dst non-local\n";
		} else {
			my $recip = $dnet->is_req($act->{dlink}, $snet);
			print $recip ? " dst req:$recip" : " dst new req";
			$recip = 'any' if $recip && $act->{override};
			if ($recip && ($recip eq 'any' || lc $recip eq lc $act->{slink})) {
				print ' => linking!';
				# there has already been a request to link this channel to that network
				# also, if it was not an override, the request was for this pair of channels
				&Janus::append(+{
					type => 'LSYNC',
					src => $dnet,
					dst => $snet,
					chan => $dnet->chan($act->{dlink},1),
					linkto => $act->{slink},
					linkfile => $act->{linkfile},
				});
			}
			print "\n";
		}
	}, CHATOPS => jparse => sub {
		my $act = shift;
		$act->{msg} = '[remote] '.$act->{msg} if $act->{src} eq $Janus::interface;
		undef;
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
