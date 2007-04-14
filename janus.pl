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

Channel->modload();
Nick->modload();
Network->modload();
Interface->modload('janus2');
JConf->modload();

my $conf = JConf->new(shift);
my $read = $conf->{readers};
$Janus::conf = $conf;
$conf->rehash();

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
				Janus::in_local($net, @parsed);
			} else {
				Janus::in_janus($net, @parsed);
			}
		}
		$$l[1] = $recvq;
		if (!$len) {
			$read->remove($l);
			Janus::delink($net);
		}
	}
}
