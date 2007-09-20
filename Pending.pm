# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Pending;
use strict;
use warnings;
use Persist;

our($VERSION) = '$Rev$' =~ /(\d+)/;

my @buffer   :Persist('buffer');
my @delegate :Persist('delegate');
my @peer     :Persist('peer')    :Arg('peer');

sub _init {
	my $net = shift;
	my($addr,$port) = $Conffile::inet{addr}->($peer[$$net]);
	print "Pending connection #$$net from $addr:$port\n";
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
	if ($line =~ /SERVER (\S+)/) {
		for my $id (keys %Conffile::netconf) {
			next if $Janus::nets{$id};
			my $nconf = $Conffile::netconf{$id};
			if ($nconf->{server} && $nconf->{server} eq $1) {
				my $type = 'Server::'.$nconf->{type};
				&Janus::load($type) or next;
				$rnet = &Persist::new($type, id => $id);
				print "Shifting new connection #$$pnet to $type network $id\n";
				$rnet->intro($nconf, $peer[$$pnet]);
				&Janus::insert_full({
					type => 'NETLINK',
					net => $rnet,
				});
				last;
			}
		}
		my $q = delete $Janus::netqueues{$pnet->id()};
		if ($rnet) {
			$delegate[$$pnet] = $rnet;
			$$q[3] = $rnet;
			$Janus::netqueues{$rnet->id()} = $q;
			for my $l (@{$buffer[$$pnet]}) {
				&Janus::in_socket($rnet, $l);
			}
		}
	} elsif ($line =~ /^<InterJanus /) {
		my $q = delete $Janus::netqueues{$pnet->id()};
		&Janus::load('Server::InterJanus');
		my $ij = Server::InterJanus->new();
		print "Shifting new connection #$$pnet to InterJanus link\n";
		my @out = $ij->parse($line);
		if (@out && $out[0]{type} eq 'InterJanus') {
			$$q[3] = $ij;
			$Janus::netqueues{$ij->id()} = $q;
			$ij->intro($Conffile::netconf{$ij->id()}, 1);
		}
		return @out;
	}
	();
}

sub dump_sendq { '' }

1;
