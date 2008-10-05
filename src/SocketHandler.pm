package SocketHandler;
use strict;
use warnings;
use Persist;
# base class for objects handling socket input

our $ping;
our @pingt;
&Persist::register_vars(qw(pingt));

sub pingall {
	my $timeout = $Janus::time - 100;
	my @all = @Connection::queues;
	for my $q (@all) {
		my $net = $q->[&Connection::NET];
		next if ref $net eq 'Listener';
		$pingt[$$net] ||= $Janus::time; # first-time ping
		my $last = $pingt[$$net];
		if ($last && $last < $timeout) {
			&Connection::delink($net, 'Ping Timeout');
		} else {
			$net->send(+{ type => 'PING', ts => $Janus::time });
		}
	}
}

=item SocketHandler::in_socket($src,$line)

Processes a single line which came in from the given network's socket.
No terminating newline.

=cut

sub in_socket {
	my($src,$line) = @_;
	$pingt[$$src] = $Janus::time;
	my @act;
	eval {
		@act = $src->parse($line);
		1;
	} or do {
		&Event::named_hook('die', $@, @_);
		&Log::err_in($src, "Unchecked exception in parsing");
	};
	$_->{except} = $src for @act;
	&Event::insert_full(@act);
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
