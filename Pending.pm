# Copyright (C) 2007 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Pending;
use strict;
use warnings;
use Persist;
use Connection;

our(@buffer, @delegate, @peer);
&Persist::register_vars(qw(buffer delegate peer));
&Persist::autoinit('peer');

sub _init {
	my $net = shift;
	my($addr,$port) = $Conffile::inet{addr}->($peer[$$net]);
	&Debug::alloc($net, 1, "from $addr:$port");
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
			next if $Janus::nets{$id};
			my $nconf = $Conffile::netconf{$id};
			if ($nconf->{server} && $nconf->{server} eq $1) {
				my $type = 'Server::'.$nconf->{type};
				&Janus::load($type) or next;
				$rnet = &Persist::new($type, id => $id);
				&Debug::info("Shifting new connection #$$pnet to $type network $id");
				$rnet->intro($nconf, $peer[$$pnet]);
				&Janus::insert_full({
					type => 'NETLINK',
					net => $rnet,
				});
				last;
			}
		}
		&Connection::reassign($pnet, $rnet);
		if ($rnet) {
			$delegate[$$pnet] = $rnet;
			for my $l (@{$buffer[$$pnet]}) {
				&Janus::in_socket($rnet, $l);
			}
		}
	} elsif ($line =~ /^<InterJanus /) {
		&Janus::load('Server::InterJanus');
		my $ij = Server::InterJanus->new();
		&Debug::info("Shifting new connection #$$pnet to InterJanus link");
		my @out = $ij->parse($line);
		if (@out && $out[0]{type} eq 'JNETLINK') {
			&Connection::reassign($pnet, $ij);
			$ij->intro($Conffile::netconf{$ij->id()}, 1);
			return @out;
		}
		&Connection::reassign($pnet, undef);
	}
	();
}

sub send { }

sub dump_sendq { '' }

1;
