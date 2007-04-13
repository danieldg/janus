#!/usr/bin/perl -w
use strict;
BEGIN { push @INC, '.' }
use Janus;
use Channel;
use Nick;
use Network;
use Interface;
use JConf;

$| = 1;

my $janus = Janus->new();
Channel->modload($janus);
Nick->modload($janus);
Network->modload($janus);
Interface->modload($janus,'janus2');
JConf->modload($janus);

my $conf = JConf->new(shift);
my $read = $conf->{readers};
$janus->setconf($conf);

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
