#!/usr/bin/perl
# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
use strict;
use warnings;
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

our $BKPT;
our $VERSION = 'replay';

my $logfile = shift or do {
	print "Use: $0 <logfile> [<conffile> [<dumpfile>]]\n";
	exit 1;
};

my $conffile = shift;

open my $console, '>&STDOUT' or die $!;
open my $log, $logfile or die $!;

require Log::Debug;
@Log::listeners = $Log::Debug::INST;
&Log::dump_queue();

$| = 1;
$SIG{PIPE} = 'IGNORE';
$SIG{CHLD} = 'IGNORE';

&Janus::load('Conffile') or die;
&Janus::load('Replay') or die;

if ($ARGV[0] && $ARGV[0] =~ /(.+)/) {
	my $dumpfile = $1;
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
my $KV = do {
	my $u;
	bless \$u, 'Server::InterJanus';
};

while (<$log>) {
	print ">$_";
	if ($BKPT && $. >= $BKPT) {
		BEGIN { print "Set breakpoint on line ".(__LINE__+1)."\n"; }
		print $console "BREAK\n";
		$BKPT = 0;
	}
	if (s/^!//) {
		print $console "EVAL: $_";
		eval;
	} elsif (/^\e\[33mACTION: <INITCONF(?: file="(.*)")?>\e\[m/) {
		$state = NONE;
		$conffile ||= $1 || 'janus.conf';
		my $act = { type => 'INITCONF', file => $conffile };
		&Event::insert_full($act);

		for (values %Conffile::netconf) {
			$_->{autoconnect} = 0;
		}
	} elsif (/^\e\[33mACTION: <INIT /) {
		&Event::insert_full({ type => 'INIT', args => [ $conffile ] });
	} elsif (/^\e\[33mACTION: <RUN>/) {
		&Event::insert_full({ type => 'RUN' });
	} elsif (/^\e\[36minfo: Autoconnecting (\S+)\e\[m$/) {
		print "Fake autoconnect $1\n";
		$state = NONE;
		my $id = $1;
		next if $Janus::nets{$id} || $Janus::ijnets{$id} || $Janus::pending{$id};
		my $nconf = $Conffile::netconf{$id} or die $id;
		$nconf->{autoconnect} = 1;
		unshift @Event::qstack, [];
		&Conffile::connect_net(undef, $id);
		$nconf->{autoconnect} = 0;
		&Event::_runq(shift @Event::qstack);
	} elsif (/^\e\[36minfo: Listening on (\S+)\e\[m$/) {
		print "Fake listener on $1\n";
		my $id = $1;
		&Conffile::connect_net(undef, 'LISTEN:'.$1);
	} elsif (/^\e\[31mERR: Could not listen on port (\S+):/) {
		my $id = 'LISTEN:'.$1;
		my $l = find_ij $id;
		$l->close();
		&Connection::del($l);
	} elsif (/^\e\[32mIN\@(\S*): (<InterJanus( .*>))\e\[0?m$/) {
		$state = IN;
		my($cid,$line,$ij,$tmp) = ($1,$2,undef,{});
		$_ = $3;
		$KV->kv_pairs($tmp);
		die if $cid !~ /^\d+$/ && $tmp->{id} ne $cid;
		$ij = find_ij $tmp->{id};

		if ($ij) {
			&Event::insert_full($ij->parse($line));
		} else {
			$ij = Server::InterJanus->new() unless $ij;
			my @out = $ij->parse($line);
			next unless @out && $out[0]->{type} eq 'JNETLINK';
			$ij->intro($Conffile::netconf{$ij->id()}, 1);
			&Event::insert_full(@out);
			&Connection::add(1, $ij);
		}
	} elsif (/^\e\[32mIN\@(\S+): (.*)\e\[m$/) {
		$state = IN;
		my($nid, $line) = ($1,$2);
		my $net = $Janus::nets{$nid} || $Janus::ijnets{$nid} || $Janus::pending{$nid};
		if (!$net) {
			print "Unknown network in: $_\n";
			die;
		}
		&Event::in_socket($net, $line);
	} elsif (/^\e\[34mOUT\@(\S+): /) {
		next if $state == DUMP || $Janus::ijnets{$1};
		$state = DUMP;
		$_->[0]->dump_sendq() for @Connection::queues;
	} elsif (/^\e\[33mACTION <(J?NETSPLIT)( .*>)\e\[m$/) {
		$state = IN;
		my $act = { type => $1 };
		my $txt = $_ = $2;
		$KV->kv_pairs($act);
		unless (defined $act->{net}) {
			# probably split an IJ net before it was introduced
			if ($txt =~ / net=j:(\S+) /) {
				$act->{net} = find_ij $1;
			}
		}
		&Event::insert_full($act);
	} elsif (/^\e\[1;30mTimestamp: (\d+)\e\[m$/) {
		my $ts = $1;
		$_->[0]->dump_sendq() for @Connection::queues;
		&Event::timer($ts);
	} else {
		$state = NONE;
	}
}

eval { &Janus::load('Commands::Debug'); &Commands::Debug::dump_now('End of replay'); };
eval { &Janus::load('Commands::Verify'); &Commands::Verify::verify(); };
