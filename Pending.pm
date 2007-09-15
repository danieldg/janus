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
	print "Pending connection from $addr:$port\n";
	# TODO authenticate these
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
			my $nconf = $Conffile::netconf{$id};
			if ($nconf->{server} && $nconf->{server} eq $1) {
				&Janus::delink($Janus::nets{$id}, 'Replaced by new connection') if $Janus::nets{$id};
				my $type = $nconf->{type};
				$rnet = eval "use $type; return ${type}->new(id => \$id)";
				next unless $rnet;
				print "Shifting new connection to $type network $id\n";
				$rnet->intro($nconf, 1);
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
	}
	();
}

sub dump_sendq { '' }

1;
