# Copyright (C) 2008-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Multiplex;
use strict;
use warnings;
use integer;

our $master_api;
BEGIN {
	die "Cannot override Connection" if $Connection::PRIMARY;
	die "Cannot reload: Multiplex API too old" if $master_api && $master_api < 10;
}

our($sock, $tblank, $dbg);
&Janus::static(qw(sock tblank dbg));

our @active;
our %waiting;
unless (defined $tblank) {
	$tblank = ``;
}

sub cmd {
	print $dbg ">>> $_[0]\n" if $dbg;
	print $sock "$_[0]\n";
}

sub line {
	my $r = <$sock>;
	if (defined $r) {
		chomp $r;
		print $dbg "<<< $r\n" if $dbg;
		return $r;
	}
	die "Unexpected read error: $!";
}

&Event::command_add({
	cmd => 'reboot',
	help => 'Restarts the worker process of janus',
	acl => 'die',
	section => 'Admin',
	code => sub {
		cmd($master_api == 10 ? 'S' : 'X');
		&Log::audit($_[0]->netnick . ' initiated a worker reboot');
		@Log::listeners = (); # will be restored on a rehash
		&Log::info('Worker reboot complete'); # will be complete when displayed
		&Janus::jmsg($_[1], 'Done');
	},
});

sub find {
	local $_;
	for (@active) {
		return $_ if $$_ == $_[0];
	}
	undef;
}

sub timestep {
	my $reboot = 0;
	while (1) {
		my $now = line();
		if ($now =~ /^(\d+) (.*)/) {
			my($nid, $line) = ($1,$2);
			my $net = find($nid);
			$net->in_socket($tblank . $line) if $net;
		} elsif ($now =~ /^T (\d+)/) {
			&Event::timer($1);
			last;
		} elsif ($now =~ /^D (\d+) (.*)/) {
			my $net = find($1);
			if ($net) {
				$waiting{$1} = 1;
				$net->delink($2);
			} elsif (!delete $waiting{$1}) {
				&Log::warn("Multiplex delink on unknown network ID $1: $2");
			}
		} elsif ($now =~ /^P (\d+) (\S+)/) {
			my($lid, $addr) = ($1,$2);
			my $lnet = find($lid) or next;
			my $net = $lnet->init_pending($addr);
			if ($net) {
				my($sslkey, $sslcert, $sslca) = &Conffile::find_ssl_keys($net, $lnet);
				$sslkey ||= '';
				$sslcert ||= '';
				$sslca ||= '';
				if ($master_api == 10) {
					cmd("LA $lid $$net $sslkey $sslcert $sslca");
				} else {
					cmd("LA $lid $$net");
					cmd("SS $sslkey $sslcert $sslca") if $sslkey;
				}
				push @active, $net;
			} else {
				cmd("LD $lid");
			}
		} elsif ($now eq 'Q') {
			last;
		} elsif ($now eq ($master_api == 10 ? 'S' : 'X')) {
			$reboot++;
			last;
		} else {
			&Log::err('Bad Multiplex line '.$now);
		}
	}
	
	for my $net (@active) {
		eval {
			my $sendq = $net->dump_sendq();
			for (split /[\r\n]+/, $sendq) {
				cmd("$$net $_");
			}
			1;
		} or &Log::err_in($net, "dump_sendq died: $@");
	}

	if ($reboot) {
		open my $dump, '>janus-state.dat';
		&Janus::load('Snapshot');
		&Snapshot::dump_to($dump, 1);
		cmd('R janus-state.dat');
		exit 0;
	}
}

package Connection;

sub drop_socket {
	my $net = shift;
	local $_;
	for (0..$#Multiplex::active) {
		next unless $Multiplex::active[$_] == $net;
		splice @Multiplex::active, $_, 1;
		unless (delete $waiting{$$net}) {
			$waiting{$$net} = $net;
		}
		Multiplex::cmd("D $$net");
		return 1;
	}
	return 0;
}

sub list {
	@Multiplex::active
}

sub init_listen {
	my($net, $addr, $port) = @_;
	$addr ||= '';
	Multiplex::cmd("IL $$net $addr $port");
	push @Multiplex::active, $net;
}

sub init_connection {
	my($net, $addr, $port, $bind, $sslkey, $sslcert, $sslca) = @_;
	$bind ||= '';
	$sslkey ||= '';
	$sslcert ||= '';
	$sslca ||= '';
	if ($Multiplex::master_api == 10) {
		Multiplex::cmd("IC $$net $addr $port $bind $sslkey $sslcert $sslca");
	} else {
		Multiplex::cmd("IC $$net $addr $port $bind");
		Multiplex::cmd("SC $$net $sslkey $sslcert $sslca") if $sslkey;
	}
	push @Multiplex::active, $net;
}

1;
