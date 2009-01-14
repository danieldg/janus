# Copyright (C) 2007-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Listener;
use strict;
use warnings;
use SocketHandler;
use Persist 'SocketHandler';

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
	my($self, $addr) = @_;

	my $net;
	my $nconf;
	for my $id (keys %Conffile::netconf) {
		next if $Janus::nets{$id} || $Janus::pending{$id} || $Janus::ijnets{$id};
		$nconf = $Conffile::netconf{$id};
		if ($nconf->{linkaddr} && $nconf->{linkaddr} eq $addr) {
			my $type = 'Server::'.$nconf->{type};
			&Janus::load($type) or next;
			$net = Persist::new($type, id => $id);
			$Janus::pending{$id} = $net;
			&Log::info("Incoming connection from $addr for $type network $id (#$$net)");
			$net->intro($nconf, $addr);
			last;
		}
	}
	unless ($net) {
		&Log::info("Rejecting connection from $addr, no matching network definition found");
		return undef;
	}
	return $net;
}

sub dump_sendq { '' }

1;
