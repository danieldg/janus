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
	push @INC, '.';
}
use Janus;
use POSIX 'setsid';

our $VERSION = '1.11';

$| = 1;
$SIG{PIPE} = 'IGNORE';
$SIG{CHLD} = 'IGNORE';

&Janus::load($_) or die for qw(Conffile Interface Actions Commands::Core);

open my $log, $ARGV[0];

use constant {
	NONE => 0,
	DUMP => 1,
	IN => 2,
};
my $state = NONE;

while (<$log>) {
	if (/\e\[33m   ACTION <INIT( .*>)\e\[m/) {
		$state = NONE;
		my $act = { type => 'INIT' };
		$_ = $1;
		$EventDump::INST->kv_pairs($act);
		&Janus::insert_full($act);

		%Conffile::inet = (
			type => 'REPLAY',
			listn => sub { 1 },
			conn => sub { 1 },
			addr => sub { 'nowhere', 5 },
		);
		&Janus::insert_full({ type => 'RUN' });
	} elsif (/^\e\[36m Autoconnecting (\S+)\e\[m$/) {
		$state = NONE;
		my $id = $1;
		next if $Janus::nets{$id} || $Janus::ijnets{$id};
		my $nconf = $Conffile::netconf{$id} or die $id;
		my $type = 'Server::'.$nconf->{type};
		&Janus::load($type) or die;
		my $net = &Persist::new($type, id => $id);
		$net->intro($nconf);
		&Janus::append({ type => NETLINK => net => $net });
	} elsif (/^\e\[34m   OUT/) {
		next if $state == DUMP;
		$state = DUMP;
		$_->[&Connection::NET]->dump_sendq() for @Connection::queues;
	} elsif (/^\e\[32m    IN\@(\S*) (<InterJanus( .*>))\e\[0?m$/) {
		$state = IN;
		my($cid,$line,$ij,$tmp) = ($1,$2,undef,{});
		$_ = $3;
		$EventDump::INST->kv_pairs($tmp);
		die if $cid && $tmp->{id} ne $cid;
		$cid = $tmp->{id};

		for (@Connection::queues) {
			my $net = $_->[&Connection::NET];
			next unless $net->isa('Server::InterJanus');
			next unless $net->id() eq $cid;
			$ij = $net;
		}
		$line =~ s/ts="\d+"/ts="$Janus::time"/;
		if ($ij) {
			&Janus::insert_full($ij->parse($line));
		} else {
			$ij = Server::InterJanus->new() unless $ij;
			my @out = $ij->parse($line);
			$ij->intro($Conffile::netconf{$ij->id()}, 1);
			&Janus::insert_full(@out);
		}
	} elsif (/^\e\[32m    IN\@(\S+) (.*)\e\[0?m$/) {
		$state = IN;
		my($nid, $line) = ($1,$2);
		my $net = $Janus::nets{$nid} || $Janus::ijnets{$nid} || die;
		&Janus::in_socket($net, $line);
	} elsif (/^\e\[33m   ACTION <NETSPLIT( .*>)\e\[m$/) {
		$state = IN;
		my $act = { type => 'NETSPLIT' };
		$EventDump::INST->kv_pairs($act);
		&Janus::insert_full($act);
	} else {
		$state = NONE;
	}
}
