# Copyright (C) 2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Log;
use strict;
use warnings;
use Carp;

# log level => \&stringifier
#  Output: (IRC-color, header, message)
our %action = (
	'err' => sub {
		(5, 'ERR', join ' ', @_);
	}, 'warn' => sub {
		(6, 'WARN', join ' ', @_);
	}, 'info' => sub {
		(10, 'info', join ' ', @_)
	}, 'info_in' => sub {
		my $src = shift;
		my $name =
			$src->isa('Network') ? ($src->name.'='.$src->gid) :
			$src->isa('Channel') ? $src->real_keyname :
			$src->isa('Nick') ? $src->netnick :
			$src;
		(10, "\@$name", join ' ', @_);
	}, 'warn_in' => sub {
		my $src = shift;
		my $name =
			$src->isa('Network') ? ($src->name.'='.$src->gid) :
			$src->isa('Channel') ? $src->real_keyname :
			$src->isa('Nick') ? $src->netnick :
			$src;
		(6, "WARN\@$name", join ' ', @_);
	}, 'err_in' => sub {
		my $src = shift;
		my $name =
			$src->isa('Network') ? ($src->name.'='.$src->gid) :
			$src->isa('Channel') ? $src->real_keyname :
			$src->isa('Nick') ? $src->netnick :
			$src;
		(5, "ERR\@$name", join ' ', @_);
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
	}, 'netin' => sub {
		my($net, $line) = @_;
		my $name =
			$net->can('name') ? $net->name() :
			$net->can('id') ? $net->id() : 0;
		$name ||= $$net;
		(3, "IN\@$name", $line);
	}, 'netout' => sub {
		my($net, $line) = @_;
		my $name =
			$net->can('name') ? $net->name() :
			$net->can('id') ? $net->id() : 0;
		$name ||= $$net;
		(2, "OUT\@$name", $line);
	}, 'timestamp' => sub {
		(14, 'Timestamp', $_[0])
	}, 'debug' => sub {
		(14, 'debug', $_[0])
	}, 'debug_in' => sub {
		my $src = shift;
		my $name =
			$src->isa('Network') ? ($src->name.'='.$src->gid) :
			$src->isa('Channel') ? $src->real_keyname :
			$src->isa('Nick') ? $src->netnick :
			$src;
		(14, "debug\@$name", join ' ', @_);
	}, 'audit' => sub {
		(9, 'AUDIT', $_[0])
	}, 'command' => sub {
		(13, 'janus', join ' ', $_[0]->netnick, $_[1])
	}, 'poison' => sub {
		my($pkg, $file, $line, $called, $ifo, @etc) = @_;
		if ($ifo->{refs} == 1 && &Janus::load('Commands::Debug')) {
			eval { &Commands::Debug::dump_now('poison', @_) };
		}
		(14, 'poison', "Reference to $ifo->{class}->$called at $file line $line for #$ifo->{id} (count=$ifo->{refs})");
	},
);

our @queue;
our @listeners;

our @ANSI = ('',qw(30 34 32 1;31 31 35 33 1;33 1;32 36 1;35 1;34 1;35 1;30 37 1;37));

our($AUTOLOAD,$ftime,$fcount);
$ftime ||= 0;

&Janus::static(qw(action ANSI ftime fcount listeners));

sub AUTOLOAD {
	local $_;
	$AUTOLOAD =~ s/Log:://;
	my $lvl = $action{$AUTOLOAD};
	unless ($lvl) {
		carp "Unknown log level $AUTOLOAD";
		$AUTOLOAD = 'err';
		$lvl = $action{err} or die;
	}
	if ($ftime == $Janus::time) {
		$fcount++;
		if ($fcount == 5000) {
			$AUTOLOAD = 'err';
			$lvl = $action{err};
			@_ = ('LOG OVERFLOW');
		} elsif ($fcount > 5000) {
			return;
		}
	} else {
		($ftime,$fcount) = ($Janus::time, 0);
	}
	my @str = ($AUTOLOAD, $lvl->(@_));
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

$SIG{'__WARN__'} = sub {
	return if $_[0] =~ /^Subroutine \S+ redefined at (?:\S+\.pm|\(eval \d+\)) line \d+\.$/;
	&Log::warn(@_);
};

1;
