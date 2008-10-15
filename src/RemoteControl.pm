# Copyright (C) 2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package RemoteControl;
use strict;
use warnings;
use integer;
use Scalar::Util qw(tainted);

our $reboot;
our $sock;
our $tblank;

our @active;
unless (defined $tblank) {
	$tblank = ``;
	print "WARNING: not running in taint mode\n" unless tainted($tblank);
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
			my $net = &Connection::find($nid);
			$net->in_socket($tblank . $line) if $net;
		} elsif ($now =~ /^DELINK (\d+) (.*)/) {
			my $net = &Connection::find($1);
			if ($net) {
				$net->delink($2);
			} else {
				cmd("DELNET $1");
			}
		} elsif ($now =~ /^PEND (\d+) (\S+)/) {
			my($lid, $addr) = ($1,$2);
			my $lnet = &Connection::find($lid);
			my($net, $ssl) = $lnet->init_pending($addr);
			if ($ssl) {
				cmd("PEND-SSL $$net $ssl->{keyfile} $ssl->{certfile}");
			} elsif ($net) {
				cmd("PEND $$net");
			} else {
				cmd("DROP");
			}
			push @active, $net if $net;
		} else {
			&Log::err('Bad RemoteControl response '.$now);
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

sub add {
	my($fd, $net) = @_;
	&RemoteControl::cmd("ADDNET $fd $$net");
	push @RemoteControl::active, $net;
}

sub del {
	my $net = shift;
	local $_;
	for (0..$#RemoteControl::active) {
		next unless $RemoteControl::active[$_] == $net;
		splice @RemoteControl::active, $_, 1;
		&RemoteControl::cmd("DELNET $$net");
		return 1;
	}
	0;
}

sub find {
	local $_;
	my @r = grep { $$_ == $_[0] } @RemoteControl::active;
	&Log::err("Find on unknown network $_[0]") unless @r;
	$r[0];
}

sub list {
	@RemoteControl::active
}

sub init_listen {
	my($addr, $port) = @_;
	my $resp = &RemoteControl::ask("INITL $addr $port");
	if ($resp =~ /^FD (\d+)/) {
		return $1;
	} elsif ($resp =~ /^ERR (.*)/) {
		&Log::err("Cannot listen: $1");
	} else {
		&Log::err('Bad RemoteControl response '.$resp);
	}
	return undef;
}

sub init_conn {
	my($addr, $port, $bind, $ssl) = @_;
	$bind ||= '';
	$ssl ||= '';
	my $resp = &RemoteControl::ask("INITC $addr $port $bind $ssl");
	if ($resp =~ /^FD (\d+)/) {
		return $1;
	} elsif ($resp =~ /^ERR (.*)/) {
		&Log::err("Cannot connect: $1");
	} else {
		&Log::err('Bad RemoteControl response '.$resp);
	}
	return undef;
}

1;
