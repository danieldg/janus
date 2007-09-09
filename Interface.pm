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
	MSG => parse => sub {
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
		return unless $act->{dst} eq $Janus::interface;
		&Janus::append(+{
			type => 'CONNECT',
			dst => $act->{dst},
			net => $act->{net},
		});
	},
);

sub parse { () }
sub send { }
sub request_newnick { $_[2] }
sub request_cnick { $_[2] }
sub release_nick { }
sub all_nicks { $Janus::interface }
sub all_chans { () }

1;
