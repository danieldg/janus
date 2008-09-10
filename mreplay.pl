#!/usr/bin/perl
# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
use strict;
use warnings;
use Socket;
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

my %drone;

for my $drone (@drones) {
	my($ctl, $cmds);
	socketpair $ctl, $cmds, AF_UNIX, SOCK_STREAM, PF_UNSPEC;
	my $pid = fork;
	die "cannot fork" unless defined $pid;
	if ($pid) {
		close $cmds;
		my $log = open my $fh, '<', $drone->[0];
		<$ctl> =~ /^INIT (\S+)/ or die "Bad init on drone";
		my $name = $1;
		$drone{$name} = [ $ctl, $fh, 0, $name, '' ];
	} else {
		close $ctl;
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

	require Log::Debug;
	@Log::listeners = $Log::Debug::INST;
	&Log::dump_queue();

	&Janus::load('Conffile') or die;
	&Janus::load('Replay') or die;

	if ($dump) {
		$dump = "./$dump" unless $dump =~ m#^/#;
		&Replay::run($conffile, $dump);
	} else {
		my $act = { type => 'INITCONF', file => $conffile };
		&Janus::insert_full($act);

		for (values %Conffile::netconf) {
			$_->{autoconnect} = 0;
		}

		&Janus::insert_full({ type => 'INIT', args => [ $conffile ] });

		print $cmds 'INIT '.$RemoteJanus::self->id()."\n";

		&Janus::insert_full({ type => 'RUN' });
	}

	while (<$cmds>) {
		my($cmd, $line) = /^(\S+) (.*)$/ or die "Bad line in: $_";
		if ($cmd eq 'TS') {
			for my $q (@Connection::queues) {
				my $net = $_->[0];
				my $out = $net->dump_sendq();
				if ($net->isa('Server::InterJanus')) {
					my $id = $net->id;
					print "OUT-$id $_" for split /\n+/, $out;
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
				my $net = $_->[0];
				my $out = $net->dump_sendq();
				if ($net->isa('Server::InterJanus')) {
					my $id = $net->id;
					print "OUT-$id $_" for split /\n+/, $out;
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
			&Conffile::connect_net(undef, $id);
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
			&Janus::insert_full($act);
		} elsif ($cmd eq 'DIE') {
			last;
		} else {
			die "Bad line $cmd $line";
		}
	}
	eval { &Janus::load('Commands::Debug'); &Commands::Debug::dump_now('End of replay'); };
	eval { &Janus::load('Commands::Verify'); &Commands::Verify::verify(); };
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
		my $cmd = $d->[DCMD];
		my $ts = $d->[DTIME];
		my $name = $d->[DNAME];
		my $logfh = $d->[DLOG];
		my $sending = 0;

		print $cmd $d->[SENDQ];
		$d->[SENDQ] = '';

		if ($ts) {
			print $cmd "TS $ts\n";
			while (<$cmd>) {
				last if /^\+TS/;
				/^OUT-(\S+) (.*)/ or die "Bad line in SEND rv: $_";
				die unless $drone{$1};
				$drone{$1}[SENDQ] .= "IN-$name $2\n";
			}
		}
		while (<$logfh>) {
			if (!defined) {
				print $cmd "DIE\n";
				close $cmd;
				$d->[DCMD] = undef;
				last;
			} elsif (/^\e\[1;30mTimestamp: (\d+)\e\[m$/) {
				$d->[DTIME] = $1;
				last;
			} elsif (/^\e\[36minfo: Autoconnecting (\S+)\e\[m$/) {
				print $cmd "ADD $1\n";
			} elsif (/^\e\[36minfo: Listening on (\S+)\e\[m$/) {
				print $cmd "ADD LISTEN:$1\n";
			} elsif (/^\e\[31mERR: Could not listen on port (\S+):/) {
				print $cmd "LISTENFAIL $1\n";
			} elsif (/^\e\[32mIN\@(\S+): (.*)\e\[m$/) {
				next if $drone{$1};
				print $cmd "IN-$1 $2\n";
			} elsif (/^\e\[34mOUT\@(\S+): /) {
				$sending++;
				next if $sending == 2 || $drone{$1};
				$sending = 2;
				print $cmd "SEND\n";
				while (<$cmd>) {
					last if /^\+SEND/;
					/^OUT-(\S+) (.*)/ or die "Bad line in SEND rv: $_";
					die unless $drone{$1};
					$drone{$1}[SENDQ] .= "IN-$name $2\n";
				}
			} elsif (/^\e\[33mACTION <(J?NETSPLIT)( .*>)\e\[m$/) {
				print $cmd "$1$2\n";
			}
			$sending-- if $sending; # goes to 0 after one non-OUT line
		}
	}
}