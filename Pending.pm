package Pending; {
use Object::InsideOut;
use strict;
use warnings;

my @buffer :Field;
my @delegate :Field;
my @peer :Field :Arg(peer);

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
		my $rnet;
		for my $id (keys %Conffile::netconf) {
			my $nconf = $Conffile::netconf{$id};
			if ($nconf->{server} && $nconf->{server} eq $1) {
				&Janus::delink($Janus::nets{$id}, 'Replaced by new connection') if $Janus::nets{$id};
				my $type = $nconf->{type};
				$rnet = eval "use $type; return ${type}->new(id => \$id)";
				next unless $rnet;
				print "Shifting new connection to $type network $id\n";
				$rnet->intro($nconf, 1);
				&Janus::link($rnet);
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

} 1;
