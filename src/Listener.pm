# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Listener;
use strict;
use warnings;
use SocketHandler;
use Persist 'SocketHandler';
use Pending;

our @id;
&Persist::register_vars('id');
&Persist::autoget('id');

our %open;

sub _init {
	my($net, $arg) = @_;
	my $id = $id[$$net] = $arg->{id};
	$open{$id} = $net;
}

sub close {
	my $net = shift;
	delete $open{$id[$$net]};
}

sub init_pending {
	my($self, $sock, $addr) = @_;
	my $conf = $Conffile::netconf{$id[$$self]};
	return undef unless $conf;
	my $net = Pending->new(addr => $addr);
	if ($conf->{linktype} =~ /ssl/) {
		IO::Socket::SSL->start_SSL($sock, 
			SSL_server => 1, 
			SSL_startHandshake => 0,
			SSL_key_file => $conf->{keyfile},
			SSL_cert_file => $conf->{certfile},
		);
		if ($sock->isa('IO::Socket::SSL')) {
			$sock->accept_SSL();
		} else {
			&Debug::err("cannot initiate SSL pend on $id[$$self]");
		}
	}
	$net;
}

sub dump_sendq { '' }

1;
