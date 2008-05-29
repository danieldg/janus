# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Pending;
use strict;
use warnings;
use SocketHandler;
use Persist 'SocketHandler';

our(@buffer, @delegate, @addr);
&Persist::register_vars(qw(buffer delegate addr));
&Persist::autoinit('addr');

sub _init {
	my $net = shift;
	$addr[$$net];
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
	# TODO sort by incoming address not first line?
	if ($line =~ /SERVER (\S+)/) {
		for my $id (keys %Conffile::netconf) {
			next if $Janus::nets{$id};
			my $nconf = $Conffile::netconf{$id};
			if ($nconf->{server} && $nconf->{server} eq $1) {
				my $type = 'Server::'.$nconf->{type};
				&Janus::load($type) or next;
				$rnet = &Persist::new($type, id => $id);
				&Debug::info("Shifting new connection #$$pnet to $type network $id (#$$rnet)");
				$rnet->intro($nconf, $addr[$$pnet]);
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
		my @out = $ij->parse($line);
		if (@out && $out[0]{type} eq 'JNETLINK') {
			&Debug::info("Shifting new connection #$$pnet to InterJanus link #$$ij ".$ij->id());
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
