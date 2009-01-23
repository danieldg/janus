# Copyright (C) 2008-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Multiplex;
use strict;
use warnings;
use integer;
use Scalar::Util qw(tainted);

BEGIN {
	die "Cannot override Connection" if $Connection::PRIMARY;
}

our $reboot;
our $sock;
our $tblank;
our $master_api;

our @active;
unless (defined $tblank) {
	$tblank = ``;
	print "WARNING: not running in taint mode\n" unless tainted($tblank);
}
$master_api ||= 1;
if ($RemoteControl::master_api) {
	@active = @RemoteControl::active;
	$sock ||= $RemoteControl::sock;
	$master_api = $RemoteControl::master_api;
	@RemoteControl::active = ();
	$RemoteControl::master_api = 0;
}

&Janus::static(qw(reboot sock tblank));

&Event::command_add({
	cmd => 'reboot',
	help => 'Restarts the worker process of janus',
	acl => 'die',
	code => sub {
		$reboot++;
		&Log::audit($_[0]->netnick . ' initiated a worker reboot');
		@Log::listeners = (); # will be restored on a rehash
		&Log::info('Worker reboot complete'); # will be complete when displayed
		&Janus::jmsg($_[1], 'Done');
	},
});

sub cmd {
#	print ">>> $_[0]\n";
	print $sock "$_[0]\n";
}

sub ask {
#	print ">>? $_[0]\n";
	print $sock "$_[0]\n";
	my $r = <$sock>;
	if (defined $r) {
		chomp $r;
#		print "<<< $r\n";
		return $r;
	}
	die "Unexpected read error: $!";
}

sub find {
	local $_;
	my @r = grep { $$_ == $_[0] } @active;
	&Log::err("Find on unknown network $_[0]") unless @r;
	$r[0];
}

sub timestep {
	my $next = &Event::next_event($Janus::time + 60);
	my $now = ask("W $next");
	&Event::timer(time);
	while (1) {
		$now = ask('N');
		if ($now eq 'L') {
			last;
		} elsif ($now =~ /^(\d+) (.*)/) {
			my($nid, $line) = ($1,$2);
			my $net = find($nid);
			$net->in_socket($tblank . $line) if $net;
		} elsif ($now =~ /^DELINK (\d+) (.*)/) {
			my $net = find($1);
			if ($net) {
				$net->delink($2);
			} else {
				cmd("DELNET $1");
			}
		} elsif ($now =~ /^PEND (\d+) (\S+)/) {
			my($lid, $addr) = ($1,$2);
			my $lnet = find($lid);
			my $net = $lnet->init_pending($addr);
			if ($net) {
				my($sslkey, $sslcert, $sslca) = &Conffile::find_ssl_keys($net, $lnet);
				if ($sslcert) {
					cmd("PEND-SSL $$net $sslkey $sslcert $sslca");
				} else {
					cmd("PEND $$net");
				}
				push @active, $net;
			} else {
				cmd('DROP');
			}
		} else {
			&Log::err('Bad Multiplex response '.$now);
		}
	}
	
	for my $net (@active) {
		eval {
			my $sendq = $net->dump_sendq();
			for (split /\n+/, $sendq) {
				cmd("$$net $_");
			}
			1;
		} or &Log::err_in($net, "dump_sendq died: $@");
	}

	if ($reboot) {
		open my $dump, '>janus-state.dat';
		&Janus::load('Snapshot');
		&Snapshot::dump_to($dump, 1);
		cmd("REBOOT janus-state.dat");
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
		&Multiplex::cmd("DELNET $$net");
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
	if ($Multiplex::master_api >= 6) {
		my $resp = &Multiplex::ask("INITL $$net $addr $port");
		if ($resp =~ /^ERR (.*)/) {
			&Log::err("Cannot listen: $1");
			return 0;
		}
	} else {
		my $resp = &Multiplex::ask("INITL $addr $port");
		if ($resp eq 'OK') {
			Multiplex::cmd("ID $$net");
		} elsif ($resp =~ /^FD (\d+)/) {
			Multiplex::cmd("ADDNET $1 $$net");
		} else {
			&Log::err("Cannot listen: $1") if $resp =~ /^ERR (.*)/;
			return 0;
		}
	}
	push @Multiplex::active, $net;
	return 1;
}

sub init_connection {
	my($net,$addr, $port, $bind, $sslkey, $sslcert, $sslca) = @_;
	$bind ||= '';
	$sslkey ||= '';
	$sslcert ||= '';
	push @Multiplex::active, $net;
	my $resp;
	if ($Multiplex::master_api < 3) {
		my $ssl = $sslkey ? 1 : 0;
		$resp = &Multiplex::ask("INITC $addr $port $bind $ssl");
	} elsif ($Multiplex::master_api < 5) {
		$resp = &Multiplex::ask("INITC $addr $port $bind $sslkey $sslcert");
	} elsif ($Multiplex::master_api < 7) {
		&Multiplex::cmd("INITC $$net $addr $port $bind $sslkey $sslcert");
		return;
	} else {
		&Multiplex::cmd("INITC $$net $addr $port $bind $sslkey $sslcert $sslca");
		return;
	}
	if ($resp eq 'OK') {
		Multiplex::cmd("ID $$net");
	} elsif ($resp =~ /^FD (\d+)/) {
		Multiplex::cmd("ADDNET $1 $$net");
	} else {
		$resp =~ /^ERR (.*)/;
		&Log::err("Cannot connect: $1");
		pop @Multiplex::active;
	}
}

1;
