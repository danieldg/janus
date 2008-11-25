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
our $master_api;

our @active;
unless (defined $tblank) {
	$tblank = ``;
	print "WARNING: not running in taint mode\n" unless tainted($tblank);
}
$master_api ||= 1;

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
			my $net = $lnet->init_pending($addr);
			if ($net) {
				my($sslkey, $sslcert) = &Conffile::find_ssl_keys($net, $lnet);
				if ($sslcert) {
					cmd("PEND-SSL $$net $sslkey $sslcert");
				} else {
					cmd("PEND $$net");
				}
				push @active, $net;
			} else {
				cmd('DROP');
			}
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

our $OVERRIDE = 1;

sub add {
	my($fd, $net) = @_;
	if ($RemoteControl::master_api < 4) {
		&RemoteControl::cmd("ADDNET $fd $$net");
	} elsif ('' eq ref $fd) {
		&RemoteControl::cmd("ID $$net");
	} else {
		&RemoteControl::cmd(join ' ', 'INITC', $$net, @$fd);
	}
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
	return 0;
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
	if ($resp eq 'OK') {
		return 1;
	} elsif ($resp =~ /^FD (\d+)/) {
		return $1;
	} elsif ($resp =~ /^ERR (.*)/) {
		&Log::err("Cannot listen: $1");
	} else {
		&Log::err('Bad RemoteControl response '.$resp);
	}
	return undef;
}

sub init_conn {
	my($addr, $port, $bind, $sslkey, $sslcert) = @_;
	$bind ||= '';
	$sslkey ||= '';
	$sslcert ||= '';
	my $resp;
	if ($RemoteControl::master_api < 3) {
		my $ssl = $sslkey ? 1 : 0;
		$resp = &RemoteControl::ask("INITC $addr $port $bind $ssl");
	} elsif ($RemoteControl::master_api < 5) {
		$resp = &RemoteControl::ask("INITC $addr $port $bind $sslkey $sslcert");
	} else {
		return [ $addr, $port, $bind, $sslkey, $sslcert ];
	}
	if ($resp eq 'OK') {
		return 1;
	} elsif ($resp =~ /^FD (\d+)/) {
		return $1;
	} elsif ($resp =~ /^ERR (.*)/) {
		&Log::err("Cannot connect: $1");
	} else {
		&Log::err('Bad RemoteControl response '.$resp);
	}
	return undef;
}

1;
