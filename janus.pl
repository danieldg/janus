#!/usr/bin/perl -w
use strict;
BEGIN { push @INC, '.' }
use Unreal;
use Interface;
use IO::Select;

$| = 1;

my $read = IO::Select->new();
my $net1 = Unreal->new(
	linkaddr => '::1',
	linkport => 8001,
	linkname => 'janus1.testnet',
	linkpass => 'pass',
	numeric => 44,
	id => 'test1',
);
my $net2 = Unreal->new(
	linkaddr => '::1',
	linkport => 8002,
	linkname => 'janus2.testnet',
	linkpass => 'pass',
	numeric => 45,
	id => 'test2',
);
my $net3 = Unreal->new(
	linkaddr => '::1',
	linkport => 8003,
	linkname => 'janus3.testnet',
	linkpass => 'pass',
	numeric => 46,
	id => 'test3',
);


$net1->connect();
$net2->connect();
$net3->connect();

my $int = Interface->new();
$int->link($net1);
$int->link($net2);
$int->link($net3);

$read->add([$net1->{sock}, $net1]);
$read->add([$net2->{sock}, $net2]);
$read->add([$net3->{sock}, $net3]);

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
		}
		if (!$len) {
			$read->remove($l);
			$net->netsplit();
		}
	}
}
