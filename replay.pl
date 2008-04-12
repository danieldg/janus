#!/usr/bin/perl
# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
use strict;
use warnings;
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

our $BKPT;
our $VERSION = 'replay';

my $logfile = shift or do {
	print "Use: $0 <logfile> [<conffile> [<dumpfile>]]\n";
	exit 1;
};

my $conffile = shift;

open my $console, '>&STDOUT' or die $!;
open my $log, $logfile or die $!;

$| = 1;
$SIG{PIPE} = 'IGNORE';
$SIG{CHLD} = 'IGNORE';

&Janus::load($_) or die for qw(Conffile Interface Actions Commands::Core);

if ($ARGV[0] && $ARGV[0] =~ /(.+)/) {
	my $dumpfile = $1;
	&Janus::load('Replay') or die;
	$dumpfile = "./$dumpfile" unless $dumpfile =~ m#^/#;
	&Replay::run($conffile, $dumpfile);
}

use constant {
	NONE => 0,
	DUMP => 1,
	IN => 2,
};
my $state = NONE;

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

sub zero { 0 }
sub one { 1 }

while (<$log>) {
	if ($BKPT && $. >= $BKPT) {
		BEGIN { print "Set breakpoint on line ".(__LINE__+1)."\n"; }
		print $console "BREAK\n";
		$BKPT = 0;
	}
	if (s/^!//) {
		print $console "EVAL: $_";
		eval;
	} elsif (/^\e\[33m   ACTION <INIT( .*>)\e\[m/) {
		$state = NONE;
		my $act = { type => 'INIT' };
		$_ = $1;
		$EventDump::INST->kv_pairs($act);
		if ($conffile) {
			$act->{args}[1] = $conffile;
		}
		&Janus::insert_full($act);

		%Conffile::inet = (
			type => 'REPLAY',
			listn => \&zero,
			conn => \&zero,
			addr => sub { 'nowhere', 5 },
		);
		for (values %Conffile::netconf) {
			$_->{autoconnect} = 0;
		}
	} elsif (/^\e\[33m   ACTION <RUN>/) {
		&Janus::insert_full({ type => 'RUN' });
	} elsif (/^\e\[36m Autoconnecting (\S+)\e\[m$/) {
		$state = NONE;
		my $id = $1;
		next if $Janus::nets{$id} || $Janus::ijnets{$id};
		my $nconf = $Conffile::netconf{$id} or die $id;
		$nconf->{autoconnect} = 1;
		$Conffile::inet{conn} = \&one;
		unshift @Janus::qstack, [];
		&Conffile::connect_net(undef, $id);
		$nconf->{autoconnect} = 0;
		$Conffile::inet{conn} = \&zero;
		&Janus::_runq(shift @Janus::qstack);
	} elsif (/^\e\[36m Listening on (\S+)\e\[m$/) {
		my $id = $1;
		$Conffile::inet{listn} = \&one;
		&Conffile::connect_net(undef, 'LISTEN:'.$1);
		$Conffile::inet{listn} = \&zero;
	} elsif (/^\e\[31mERR: Could not listen on port (\S+):/) {
		my $id = 'LISTEN:'.$1;
		my $l = find_ij $id;
		$l->close();
		&Connection::reassign($l, undef);
	} elsif (/^\e\[34m   OUT\@\S+ <InterJanus .* ts="(\d+)"/) {
		print "\e\[0;1mTS-DeltaTo $1\e\[m\n";
		&Janus::timer($1);
	} elsif (/^\e\[34m   OUT\@(\S+)/) {
		next if $state == DUMP || !$Janus::nets{$1};
		$state = DUMP;
		$_->[&Connection::NET]->dump_sendq() for @Connection::queues;
	} elsif (/^\e\[32m    IN\@(\S*) (<InterJanus( .*>))\e\[0?m$/) {
		$state = IN;
		my($cid,$line,$ij,$tmp) = ($1,$2,undef,{});
		$_ = $3;
		$EventDump::INST->kv_pairs($tmp);
		die if $cid && $tmp->{id} ne $cid;
		$ij = find_ij $tmp->{id};

		$_ = <$log>;
		if (/^\e\[34m   OUT\@\S+ <InterJanus .* ts="(\d+)"/) {
			print "# Timestamp reset to $1\n";
			&Janus::timer($1);
		} elsif (/^\e\[31mERR: Clocks .* here=(\d+)/) {
			print "# Timestamp reset to $1\n";
			&Janus::timer($1);
		} else {
			print "# Line $_";
		}

		if ($ij) {
			&Janus::insert_full($ij->parse($line));
		} else {
			$ij = Server::InterJanus->new() unless $ij;
			my @out = $ij->parse($line);
			next unless @out && $out[0]->{type} eq 'JNETLINK';
			$ij->intro($Conffile::netconf{$ij->id()}, 1);
			&Janus::insert_full(@out);
			&Connection::add(1, $ij);
		}
	} elsif (/^\e\[32m    IN\@(\S+) (.*)\e\[0?m$/) {
		$state = IN;
		my($nid, $line) = ($1,$2);
		my $net = $Janus::nets{$nid} || $Janus::ijnets{$nid};
		if (!$net) {
			print "Unknown network in: $_\n";
			die;
		}
		&Janus::in_socket($net, $line);
	} elsif (/^\e\[33m   ACTION <(J?NETSPLIT)( .*>)\e\[m$/) {
		$state = IN;
		my $act = { type => $1 };
		my $txt = $_ = $2;
		$EventDump::INST->kv_pairs($act);
		unless (defined $act->{net}) {
			# probably split an IJ net before it was introduced
			if ($txt =~ / net=j:(\S+) /) {
				$act->{net} = find_ij $1;
			}
		}
		&Janus::insert_full($act);
	} elsif (/^\e\[33m   ACTION <LOCKACK .* expire="(\d+)" .* src=j:(\S+)>\e\[m$/) {
		next unless $2 eq $RemoteJanus::self->id();
		&Janus::timer($1-40);
	} elsif (/^\e\[0;1mTimestamp: (\d+)\e\[m$/) {
		&Janus::timer($1);
	} else {
		$state = NONE;
	}
}

eval { &Janus::load('Commands::Debug'); &Commands::Debug::dump_now(); };
eval { &Janus::load('Commands::Verify'); &Commands::Verify::verify(); };
