#!/usr/bin/perl
# Copyright (C) 2007-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
use strict;
use warnings;
use Socket;
use IO::Handle;
no warnings 'once';
BEGIN {
	# Support for taint mode: we don't acually need most of these protections
	# as the person running janus.pl is assumed to have shell access anyway.
	# The real benefit of taint mode is protecting IRC-sourced data
	$_ = $ENV{PATH};
	s/:.(:|$)/$1/;
	s/~/$ENV{HOME}/g;
	/(.*)/;
	$ENV{PATH} = $1;
	$ENV{SHELL} = '/bin/sh';
	delete @ENV{'IFS', 'CDPATH', 'ENV', 'BASH_ENV'};
}
do './src/Janus.pm' or die $@;
use POSIX 'setsid';

our $VERSION = 'mreplay';
open my $console, '>&STDOUT' or die $!;

$| = 1;
$SIG{PIPE} = 'IGNORE';
$SIG{CHLD} = 'IGNORE';

my @drones;

while (@ARGV) {
	my($log, $conf) = (shift, shift);
	my $dump;
	if (@ARGV) {
		my $dump = $ARGV[0];
		open my $df, '<', $dump;
		if (<$df> eq "\$gnicks = {\n") {
			$dump = shift;
		} else {
			$dump = undef;
		}
		close $df;
	}
	push @drones, [ $log, $conf, $dump ];
}

use constant {
	DCMD => 0,
	DLOG => 1,
	DTIME => 2,
	DNAME => 3,
	SENDQ => 4,
};

sub bkpt {
	BEGIN { print "BKPT at ".(__LINE__ + 1)."\n"; };
	0;
}

my %drone;

for my $drone (@drones) {
	my($ctl, $cmds);
	socketpair $ctl, $cmds, AF_UNIX, SOCK_STREAM, PF_UNSPEC;
	$ctl->autoflush(1);
	$cmds->autoflush(1);
	my $pid = fork;
	die "cannot fork" unless defined $pid;
	if ($pid) {
		close $cmds;
		print "Wait for init\n";
		my $log = open my $fh, '<', $drone->[0];
		<$ctl> =~ /^INIT (\S+)/ or die "Bad init on drone";
		my $name = $1;
		$drone{$name} = [ $ctl, $fh, 0, $name, '' ];
		print "Drone ready\n";
	} else {
		close $ctl;
		%drone = ();
		run_drone($cmds, $drone->[1], $drone->[2]);
		exit 0;
	}
}

sub find_ij {
	my $cid = shift;
	for (@Connection::queues) {
		my $net = $_->[&Connection::NET];
		next unless ref $net eq 'Server::InterJanus' || ref $net eq 'Listener';
		next unless $net->id() eq $cid;
		return $net;
	}
	undef;
}

sub run_drone {
	my($cmds, $conffile, $dump) = @_;

	my $KV = do {
		my $u;
		bless \$u, 'Server::InterJanus';
	};

	my $ID;

	&Janus::load('Conffile') or die;
	&Janus::load('Replay') or die;

	if ($dump) {
		$dump = "./$dump" unless $dump =~ m#^/#;
		&Replay::run($conffile, $dump);
		print $cmds "INIT ?\n";
	} else {
		my $act = { type => 'INITCONF', file => $conffile };
		&Event::insert_full($act);

		for (values %Conffile::netconf) {
			$_->{autoconnect} = 0;
		}

		&Event::insert_full({ type => 'INIT', args => [ $conffile ] });

		$ID = $RemoteJanus::self->id();

		print $cmds "INIT $ID\n";

		&Event::insert_full({ type => 'RUN' });
	}

	print "Drone $ID init complete, waiting for command\n";

	bkpt;
	while (<$cmds>) {
		my($cmd, $line) = /^(\S+) ?(.*)$/ or die "Bad line in: $_";
		if ($cmd eq 'TS') {
			for my $q (@Connection::queues) {
				my $net = $q->[0];
				my $out = $net->dump_sendq();
				if ($net->isa('Server::InterJanus')) {
					my $id = $net->id;
					print $cmds "OUT-$id $_\n" for split /\n+/, $out;
				}
			}
			&Event::timer($line);
			print $cmds "+TS\n";
		} elsif ($cmd eq 'X') {
			my @rv = eval $line;
			eval { print Data::Dumper::Dumper(\@rv); };
			print $cmds "+X\n";
		} elsif ($cmd =~ /IN-(\S+)/) {
			my $net = $Janus::nets{$1} || $Janus::ijnets{$1} || $Janus::pending{$1};
			if (!$net) {
				die "Unknown network $1 for line $line";
			}
			&Event::in_socket($net, $line);
		} elsif ($cmd eq 'SEND') {
			for my $q (@Connection::queues) {
				my $net = $q->[0];
				my $out = $net->dump_sendq();
				if ($net->isa('Server::InterJanus')) {
					my $id = $net->id;
					print $cmds "OUT-$id $_\n" for split /\n+/, $out;
				}
			}
			print $cmds "+SEND\n";
		} elsif ($cmd eq 'ADD') {
			print "Fake autoconnect $line\n";
			my $id = $line;
			next if $Janus::nets{$id} || $Janus::ijnets{$id} || $Janus::pending{$id};
			my $nconf = $Conffile::netconf{$id} or die $id;
			$nconf->{autoconnect} = 1;
			unshift @Event::qstack, [];
			&Conffile::connect_net($id);
			$nconf->{autoconnect} = 0;
			&Event::_runq(shift @Event::qstack);
		} elsif ($cmd eq 'LISTENFAIL') {
			my $id = 'LISTEN:'.$line;
			my $l = find_ij $id;
			$l->close();
			&Connection::del($l);
		} elsif ($cmd =~ /(J?NETSPLIT)/) {
			my $act = { type => $1 };
			$_ = $line;
			$KV->kv_pairs($act);
			unless (defined $act->{net}) {
				# probably split an IJ net before it was introduced
				if ($line =~ / net=j:(\S+) /) {
					$act->{net} = find_ij $1;
				}
			}
			&Event::insert_full($act);
		} elsif ($cmd eq 'DIE') {
			last;
		} elsif ($cmd eq 'B') {
			bkpt;
		} else {
			die "Bad line $cmd $line";
		}
	}
	eval { &Janus::load('Commands::Debug'); &Commands::Debug::dump_now('End of replay'); };
	eval { &Janus::load('Commands::Verify'); &Commands::Verify::verify(); };
}

bkpt;

sub cmd {
	my($q, $cmd) = @_;
	print '>'.$q->[DNAME].' '.$cmd."\n";
	my $s = $q->[DCMD];
	print $s $cmd, "\n";
}

sub sr {
	my($q, $cmd, $arg) = @_;
	my $s = $q->[DCMD];
	my $name = $q->[DNAME];
	print "»$name $cmd $arg\n";
	print $s $cmd, ' ', $arg, "\n";
	while (<$s>) {
		print "<$name $_";
		last if /^\+$cmd/;
		/^OUT-(\S+) (.*)/ or die "Bad line in $cmd sr: $_";
		die unless $drone{$1};
		$drone{$1}[SENDQ] .= "IN-$name $2\n";
	}
}

while (1) {
	my $TSMIN;
	for my $d (values %drone) {
		next unless $d->[DCMD];
		my $t = $d->[DTIME];
		$TSMIN = $t unless $TSMIN && $TSMIN < $t;
	}
	my @run = grep { $_->[DCMD] && $_->[DTIME] == $TSMIN } values %drone;

	last unless @run;

	for my $d (@run) {
		my $ts = $d->[DTIME];
		my $name = $d->[DNAME];
		my $logfh = $d->[DLOG];
		my $sending = 0;

		cmd $d, $_ for split /\n+/, $d->[SENDQ];
		$d->[SENDQ] = '';

		if ($ts) {
			sr $d, TS => $ts;
		}
		while (1) {
			$_ = <$logfh>;
			if (!defined) {
				cmd $d, 'DIE';
				close $d->[DCMD];
				$d->[DCMD] = undef;
				last;
			} elsif (/^\e\[1;30mTimestamp: (\d+)\e\[m$/) {
				$d->[DTIME] = $1;
				last;
			} elsif (/^\e\[36minfo: Autoconnecting (\S+)\e\[m$/) {
				cmd $d, "ADD $1";
			} elsif (/^\e\[36minfo: Listening on (\S+)\e\[m$/) {
				cmd $d, "ADD LISTEN:$1";
			} elsif (/^\e\[31mERR: Could not listen on port (\S+):/) {
				cmd $d, "LISTENFAIL $1";
			} elsif (/^\e\[32mIN\@(\S+): (.*)\e\[m$/) {
				next if $drone{$1};
				cmd $d, "IN-$1 $2";
			} elsif (/^\e\[34mOUT\@(\S+): /) {
				$sending++;
				next if $sending == 2 || $drone{$1};
				$sending = 2;
				sr $d, SEND => '';
			} elsif (/^\e\[33mACTION <(J?NETSPLIT)( .*>)\e\[m$/) {
				cmd $d, "$1$2";
			}
			$sending-- if $sending; # goes to 0 after one non-OUT line
		}
	}
}
