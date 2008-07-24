# Copyright (C) 2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Log;
use strict;
use warnings;
use Carp;

# log level => \&stringifier
#  Output: (IRC-color, header, message)
#  Send to Event::named_hook("LOG/$lvl")
our %action = (
	'err' => sub {
		(5, 'ERR', join ' ', @_);
	}, 'netin' => sub {
		my($net, $line) = @_;
		my $name =
			$net->can('name') ? $net->name() :
			$net->can('id') ? $net->id() : '';
		$name ||= $$net;
		(3, "IN\@$name", $line);
	}, 'netout' => sub {
		my($net, $line) = @_;
		my $name =
			$net->can('name') ? $net->name() :
			$net->can('id') ? $net->id() : $$net;
		(2, "OUT\@$name", $line);
	}, 'warn_in' => sub {
		my($src, $msg) = @_;
		my $name = $EventDump::INST->ijstr($src);
		(6, "\@$name", $msg);
	}, 'warn' => sub {
		(6, 'WARN', join ' ', @_);
	}, 'err_in' => sub {
		my($src, $msg) = @_;
		my $name = $EventDump::INST->ijstr($src);
		(5, "ERR\@$name", $msg);
	}, 'info' => sub {
		(10, '', join ' ', @_)
	}, 'alloc' => sub {
		my $obj = shift;
		(10, ref($obj), join ' ', $$obj, @_);
	}, 'action' => sub {
		(7, 'ACTION', join ' ', @_);
	}, 'hook_info' => sub {
		my($act, $msg) = @_;
		my $astr;
		eval {
			$astr = $EventDump::INST->ssend($act);
			1;
		} or do {
			$astr = "[ERR: $@]"
		};
		(10, $msg, $astr);
	}, 'hook_err' => sub {
		my($act, $msg) = @_;
		my $astr;
		eval {
			$astr = $EventDump::INST->ssend($act);
			1;
		} or do {
			$astr = "[ERR2: $@]"
		};
		(4, $msg, $astr);
	}, 'timestamp' => sub {
		(14, 'Timestamp', $_[0])
	},
);

our @queue;
our @listeners;

our @ANSI = ('',qw(30 34 32 1;31 31 35 33 1;33 1;32 36 1;35 1;34 1;35 1;30 37 1;37));

our($AUTOLOAD,$ftime,$fcount);
$ftime ||= 0;

sub AUTOLOAD {
	$AUTOLOAD =~ s/Log:://;
	my $lvl = $action{$AUTOLOAD};
	unless ($lvl) {
		carp "Unknown log level $AUTOLOAD";
		$lvl = $action{error} or die;
	}
	if ($ftime == $Janus::time) {
		return unless $fcount++ < 20;
	} else {
		($ftime,$fcount) = ($Janus::time, 0);
	}
	my @str = $lvl->(@_);
	if (@listeners) {
		$_->log(@str) for @listeners;
	} else {
		push @queue, \@str;
	}
}

sub dump_queue {
	for my $q (@queue) {
		for my $l (@listeners) {
			eval { $l->log(@$q) };
		}
	}
	@queue = ();
}

sub err_jmsg {
	my $dst = shift;
	unless ($dst) {
		my @c = caller;
		&Log::warn("Deprecated err_jmsg call in $c[0] line $c[2]");
	}
	for my $v (@_) {
		local $_ = $v; # don't use $v directly as it's read-only
		&Log::err($_);
		s/\n/ /g;
		&Interface::jmsg($dst, $_) if $Interface::janus && $dst;
	}
}

1;
