#!/usr/bin/perl -w
use strict;
BEGIN { push @INC, '.' }
use Unreal;
use Janus;
use Channel;
use Nick;
use Interface;
use IO::Select;

$| = 1;

my $janus = Janus->new();
Channel->modload($janus);
Nick->modload($janus);

Interface->modload($janus);

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

$janus->link($net1);
$janus->link($net2);
$janus->link($net3);

$read->add([$net1->{sock}, '', $net1]);
$read->add([$net2->{sock}, '', $net2]);
$read->add([$net3->{sock}, '', $net3]);

while ($read->count()) {
	my @r = $read->can_read();
	for my $l (@r) {
		my ($sock, $recvq, $net) = @$l;
		unless (defined $net) {
			# this is a listening socket; accept a new connection
			next;
		}
		my $len = sysread $sock, $recvq, 8192, length $recvq;
		while ($recvq =~ /[\r\n]/) {
			my $line;
			($line, $recvq) = split /[\r\n]+/, $recvq, 2;
			my @parsed = $net->parse($line);
			if ($net->isa('Network')) {
				$janus->in_local($net, @parsed);
			} else {
				die "TODO: in_janus";
			}
		}
		$$l[1] = $recvq;
		if (!$len) {
			$read->remove($l);
			$net->netsplit();
		}
	}
}
