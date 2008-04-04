# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Pending;
use strict;
use warnings;
use Persist 'SocketHandler';
use Connection;

our(@buffer, @delegate, @peer);
&Persist::register_vars(qw(buffer delegate peer));
&Persist::autoinit('peer');

sub _init {
	my $net = shift;
	my($addr,$port) = $Conffile::inet{addr}->($peer[$$net]);
	"from $addr:$port";
}

sub id {
	my $net = shift;
	'PEND#'.$$net;
}

sub parse {
	my($pnet, $line) = @_;
	my $rnet = $delegate[$$pnet];
	return $rnet->parse($line) if $rnet;

	push @{$buffer[$$pnet]}, $line;
	# TODO sort by incoming address not first line?
	if ($line =~ /SERVER (\S+)/) {
		for my $id (keys %Conffile::netconf) {
			next if $Janus::nets{$id};
			my $nconf = $Conffile::netconf{$id};
			if ($nconf->{server} && $nconf->{server} eq $1) {
				my $type = 'Server::'.$nconf->{type};
				&Janus::load($type) or next;
				$rnet = &Persist::new($type, id => $id);
				&Debug::info("Shifting new connection #$$pnet to $type network $id (#$$rnet)");
				$rnet->intro($nconf, $peer[$$pnet]);
				&Janus::insert_full({
					type => 'NETLINK',
					net => $rnet,
				});
				last;
			}
		}
		&Connection::reassign($pnet, $rnet);
		if ($rnet) {
			$delegate[$$pnet] = $rnet;
			for my $l (@{$buffer[$$pnet]}) {
				&Janus::in_socket($rnet, $l);
			}
		}
	}
	();
}

sub send { }

sub dump_sendq { '' }

1;
