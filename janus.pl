#!/usr/bin/perl -w
# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
use strict;
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

our $VERSION = '(J)v'.join '', '$Rev$' =~ /(\d+)/;
our $uptime = time;

my $args = @ARGV && $ARGV[0] =~ /^-/ ? shift : '';

unless ($args =~ /d/) {
	my $log = 'log/'.time;
	umask 022;
	open STDIN, '/dev/null' or die $!;
	open STDOUT, '>', $log or die $!;
	open STDERR, '>&', \*STDOUT or die $!;
	my $pid = fork;
	die $! unless defined $pid;
	if ($pid) {
		if ($args =~ /p/) {
			open P, '>janus.pid' or die $!;
			print P $pid,"\n";
			close P;
		}
		exit;
	}
	setsid;
}

$| = 1;
$SIG{PIPE} = 'IGNORE';

&Janus::load($_) or die for qw(Conffile Interface Actions Commands::Core);

&Janus::insert_full(+{ type => 'INIT', args => [ $args, @ARGV ], sendto => [] });
&Janus::insert_full(+{ type => 'RUN', sendto => [] });

eval { 
	1 while &Connection::timestep();
	1;
} || do {
	print "Aborting, error=$@\n";
	for my $net (values %Janus::nets) {
		$net = $net->jlink() if $net->jlink();
		&Janus::delink($net, 'aborting');
	}
	&Connection::abort();
};

&Janus::insert_full(+{ type => 'TERMINATE', sendto => [] });

&Janus::delink($Janus::interface->homenet(), 'Goodbye!');
$Janus::interface = undef;
print "All networks disconnected. Goodbye!\n";
&Persist::list_all_refs();
