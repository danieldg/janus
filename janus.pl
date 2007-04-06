#!/usr/bin/perl -w
use strict;
BEGIN { push @INC, '.' }
use Janus;
use Channel;
use Nick;
use Network;
use Interface;
use Unreal;
use IO::Select;

$| = 1;

my $janus = Janus->new();
Channel->modload($janus);
Nick->modload($janus);
Network->modload($janus);
Interface->modload($janus);

my $read = IO::Select->new();

sub nlink {
	my($id, @args) = @_;
	return if exists $janus->{nets}->{$id};
	my $net = Unreal->new(
		id => $id,
		@args,
	);
	$net->connect();
	$janus->link($net);
	$read->add([$net->{sock}, '', $net]);
}

sub rehash {
	nlink('t1', 
		linkaddr => '::1',
		linkport => 8001,
		linkname => 'janus1.testnet',
		linkpass => 'pass',
		linktype => 'plain',
		numeric => 44,
		netname => 'Test 1',
		translate_gline => 1,
		translate_qline => 1,
		oper_only_link => 0,
	);
	nlink('t2',
		linkaddr => '::1',
		linkport => 8002,
		linkname => 'janus2.testnet',
		linkpass => 'pass',
		linktype => 'plain',
		numeric => 45,
		netname => 'Test 2',
		translate_gline => 1,
		translate_qline => 1,
	);
	nlink('t3',
		linkaddr => '::1',
		linkport => 8003,
		linkname => 'janus3.testnet',
		linkpass => 'pass',
		linktype => 'plain',
		numeric => 46,
		netname => 'Test 3',
		translate_gline => 1,
		translate_qline => 1,
	);
}

rehash;

$janus->hook_add('main',
	REHASH => act => sub {
		rehash;
	}
);

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
			$janus->delink($net);
		}
	}
}
