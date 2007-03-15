#!/usr/bin/perl -w
use strict;
BEGIN { push @INC, '.' }
use Unreal;
use IO::Select;

my $read = IO::Select->new();
my $net1 = Unreal->new(
	linkaddr => '127.0.0.1',
	linkport => 8001,
	linkname => 'janus1.testnet',
	linkpass => 'pass',
	numeric => 44,
	id => 'test1',
);
my $net2 = Unreal->new(
	linkaddr => '127.0.0.1',
	linkport => 8002,
	linkname => 'janus2.testnet',
	linkpass => 'pass',
	numeric => 45,
	id => 'test2',
);

$net1->connect();
$net2->connect();

$read->add([$net1->{sock}, $net1]);
$read->add([$net2->{sock}, $net2]);

while ($read->count()) {
	my @r = $read->can_read();
	for my $l (@r) {
		my ($sock,$net) = @$l;
		unless (defined $net) {
			# this is a listening socket; accept a new connection
			next;
		}
		my $len = sysread $sock, $net->{recvq}, 8192, length $net->{recvq};
		while ($net->{recvq} =~ /[\r\n]/) {
			(my $line, $net->{recvq}) = split /[\r\n]+/, $net->{recvq}, 2;
			my @actions = $net->parse($line);
			for my $act (@actions) {
				my $dst = $act->{dst};
				next unless defined $dst;
				$dst->act($act);
				$dst->send($net, $act);
				$dst->postact($act);
			}

			if ($line =~ /LINKNOW/) {
				my $c1 = $net1->{chans}->{'#opers'};
				my $c2 = $net2->{chans}->{'#opers'};
				$c1->link($c2);
			}
		}
		if (!$len) {
			$read->remove($l);
			$net->netsplit();
		}
	}
}
