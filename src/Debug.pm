# Copyright (C) 2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Debug;
use strict;
use warnings;

our($IO, $action, $alloc, $info, $warn) = (1,1,1,1,1);

sub netin {
	return unless $IO;
	my($net, $line) = @_;
	my $name = 
		$net->can('name') ? $net->name() : 
		$net->can('id') ? $net->id() : $$net;
	print "\e[32m    IN\@$name $line\e[m\n";
}

sub netout {
	return unless $IO;
	my($net, $line) = @_;
	my $name = 
		$net->can('name') ? $net->name() : 
		$net->can('id') ? $net->id() : $$net;
	print "\e[34m   OUT\@$name $line\e[m\n";
}

sub warn_in {
	return unless $warn;
	my($src, $msg) = @_;
	my $name = $EventDump::INST->ijstr($src);
	print "\e[35m \@$name $msg\e[m\n";
}

sub warn {
	return unless $warn;
	print "\e[35mWARN: @_\e[m\n";
}

sub err_in {
	my($src, $msg) = @_;
	my $name = $EventDump::INST->ijstr($src);
	print "\e[31m \@$name $msg\e[m\n";
}

sub usrerr {
	print "\e[31m@_\e[m\n";
}

sub err {
	print "\e[31mERR: @_\e[m\n";
}

sub alloc {
	return unless $alloc;
	my($obj,$dir) = (shift,shift);
	print "\e[36m  ".ref($obj).":$$obj ",
		join(' ', ($dir ? 'allocated' : 'deallocated'), @_), "\e[m\n";
}

sub info {
	return unless $info;
	print "\e[36m @_\e[m\n";
}

sub action {
	return unless $action;
	print "\e[33m   ACTION @_\e[m\n";
}

sub hook_err {
	my($act, $msg) = @_;
	print "\e[35m$msg ";
	eval {
		print $EventDump::INST->ssend($act);
		1;
	} or do {
		print "[ERR2: $@]"
	};
	print "\e[m\n";
}

sub hook_info {
	return unless $info;
	my($act, $msg) = @_;
	print "\e[36m $msg ";
	eval {
		print $EventDump::INST->ssend($act);
		print "\e[m\n";
		1;
	} or do {
		print "\e[m\n";
		&Debug::err("hook_info failed: $@");
	};
}

our $LOG_TIME;

unless ($LOG_TIME) {
	$LOG_TIME = {
		code => sub {
			print "\e[0;1mTimestamp: $Janus::time\e[m\n";
		},
		repeat => 30,
	};
	&Janus::schedule($LOG_TIME);
}

1;
