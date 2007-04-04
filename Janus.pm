package Janus;
use strict;
use warnings;
# Actions: arguments: (Janus, Action)
#  parse - possible reparse point (/msg janus *) - only for local origin
#  check - reject unauthorized and/or impossible commands
#  act - Main state processing
#  send - for both local and remote
#  cleanup - Reference deletion
#
# parse and check hooks should return one of the tribool items:
#  undef if the action was not modified
#  0 if the action was modified (to detect duplicate hooks)
#  1 if the action was rejected (should be dropped)
#
# act and cleanup hooks ignore the return values.
#  $act itself should NEVER be modified at this point
#  Object linking must remain intact in the act hook

sub new {
	my $class = shift;
	my %j = (
		hook => {},
	);
	bless \%j, $class;
}

sub child {
	my $clone = shift;
	my %j = (
		hook => $clone->{hook},
	);
	bless \%j;
}

sub hook_add {
	my($j, $module) = (shift, shift);
	while (@_) {
		my ($type, $level, $sub) = (shift, shift, shift);
		warn unless $sub;
		$j->{hook}->{$type}->{$level}->{$module} = $sub;
	}
}

sub hook_del {
	my($j, $module) = @_;
	for my $t (keys %{$j->{hook}}) {
		for my $l (keys %{$j->{hook}->{$t}}) {
			delete $j->{hook}->{$t}->{$l}->{$module};
		}
	}
}

sub _hook {
	my($j, $type, $lvl, @args) = @_;
	local $_;
	my $hook = $j->{hook}->{$type}->{$lvl};
	return unless $hook;
	
	for my $mod (sort keys %$hook) {
		$hook->{$mod}->($j, @args);
	}
}

sub _mod_hook {
	my($j, $type, $lvl, @args) = @_;
	local $_;
	my $hook = $j->{hook}->{$type}->{$lvl};
	return undef unless $hook;

	my $rv = undef;
	my $taken;
	
	for my $mod (sort keys %$hook) {
		my $r = $hook->{$mod}->($j, @args);
		if (defined $r) {
			warn "Multiple modifying hooks found for $type:$lvl ($taken, $mod)" if $taken;
			$taken = $mod;
			$rv = $r;
		}
	}
	$rv;
}

sub _send {
	my($j,$act) = @_;
	my @to;
	if (exists $act->{sendto} && ref $act->{sendto}) {
		@to = @{$act->{sendto}};
	} elsif (!ref $act->{dst}) {
		warn "Action $act of type $act->{type} does not have a destination or sendto list";
		return;
	} elsif ($act->{dst}->isa('Network')) {
		@to = $act->{dst};
	} else {
		@to = $act->{dst}->sendto($act, exists $act->{sendto} ? undef : $j->{except});
	}
	for my $net (@to) {
		$net->send($act);
	}
}

sub _runq {
	my $j = shift;
	my $q = delete $j->{queue};
	return unless $q;
	for my $act (@$q) {
		$j->_run($act);
		$j->_runq();
	}
}

sub link {
	my($j,$net) = @_;
	my $id = $net->id();
	$j->{nets}->{$id} = $net;

	$j->_run(+{
		type => 'NETLINK',
		net => $net,
		sendto => [ values %{$j->{nets}} ],
	});
	$j->_runq();
}

sub delink {
	my($j,$net) = @_;
	my $id = $net->id();
	delete $j->{nets}->{$id};
	$j->{except} = $net;
	$j->_run(+{
		type => 'NETSPLIT',
		net => $net,
		sendto => [ values %{$j->{nets}} ],
	});
	$j->_runq();
	delete $j->{except};
}

sub _run {
	my($j, $act) = @_;
	if ($j->_mod_hook($act->{type}, check => $act)) {
		print "Check hook stole $act->{type}\n";
		return;
	}
	print "Acting on $act->{type}\n";
	$j->_hook($act->{type}, act => $act);
	$j->_send($act);
	$j->_hook($act->{type}, cleanup => $act);
}

sub insert {
	my $j = shift;
	for my $act (@_) {
		$j->_run($act);
	}
}

sub insert_full {
	my $j = shift;
	$j = $j->child();
	for my $act (@_) {
		$j->_run($act);
		$j->_runq();
	}
}

sub append {
	my $j = shift;
	push @{$j->{queue}}, @_;
}

sub jmsg {
	my($j, $dst) = (shift, shift);
	local $_;
	$j->append(map +{
		type => 'MSG',
		src => $j->{janus},
		dst => $dst,
		notice => !$dst->isa('Channel'), # channel notice == annoying
		msg => $_,
	}, @_);
}

sub in_local {
	my($j,$src,@act) = @_;
	$j->{except} = $src;
	for my $act (@act) {
		if ($j->_mod_hook($act->{type}, parse => $act)) {
			print "Parse hook stole $act->{type}\n";
		} else {
			$j->_run($act);
		}
		$j->_runq();
	}
	delete $j->{except};
}

sub in_janus {
	my($j,@act) = @_;
	for my $act (@act) {
		$j->_run($act);
	}
} 

1;
