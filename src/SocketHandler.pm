package SocketHandler;
use strict;
use warnings;
use Persist;
# base class for objects handling socket input

our $ping;

sub pingall {
	my $timeout = $Janus::time - 100;
	my @all = @Connection::queues;
	for my $q (@all) {
		my($net,$last) = @$q[&Connection::NET,&Connection::PINGT];
		next if ref $net eq 'Listener';
		if ($last && $last < $timeout) {
			Connection::delink($net, 'Ping Timeout');
		} else {
			$net->send(+{ type => 'PING', ts => $Janus::time });
		}
	}
}

if ($ping) {
	$ping->{code} = \&pingall;
} else {
	$ping = {
		repeat => 30,
		code => \&pingall,
	};
	Event::schedule($ping);
}

1;
