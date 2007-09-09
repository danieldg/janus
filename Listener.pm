# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Listener;
use strict;
use warnings;
use Persist;
use Pending;

our($VERSION) = '$Rev$' =~ /(\d+)/;

my @id :Persist(id) :Arg(id) :Get(id);

sub init_pending {
	my($self, $sock, $peer) = @_;
	my $net = Pending->new(peer => $peer);
	my $conf = $Conffile::netconf{$id[$$self]};
	return unless $conf;
	if ($conf->{linktype} =~ /ssl/) {
		IO::Socket::SSL->start_SSL($sock, 
			SSL_server => 1, 
			SSL_startHandshake => 0,
			SSL_key_file => $conf->{keyfile},
			SSL_cert_file => $conf->{certfile},
		);
		$sock->accept_SSL();
	}
	$Janus::netqueues{$net->id()} = [$sock, '', '', $net, 1, 0];
}

sub dump_sendq { '' }

1;
