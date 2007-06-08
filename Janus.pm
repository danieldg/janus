package Janus;
use strict;
use warnings;
use InterJanus;

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

our $interface;
our %nets;
our $last_check = time;

# (net | port number) => [ sock, recvq, sendq, (Net | undef if listening), trying_read, trying_write ]
our %netqueues;

my %hooks;
my %commands = (
	unk => +{
		code => sub {
			&Janus::jmsg($_[0], 'Unknown command. Use "help" to see available commands');
		},
	},
);

my @qstack;
my %tqueue;

my $ij_testlink = InterJanus->new();

sub hook_add {
	my $module = shift;
	while (@_) {
		my ($type, $level, $sub) = (shift, shift, shift);
		warn unless $sub;
		$hooks{$type}{$level}{$module} = $sub;
	}
}

sub hook_del {
	my $module = @_;
	for my $t (keys %hooks) {
		for my $l (keys %{$hooks{$t}}) {
			delete $hooks{$t}{$l}{$module};
		}
	}
}

sub _hook {
	my($type, $lvl, @args) = @_;
	local $_;
	my $hook = $hooks{$type}{$lvl};
	return unless $hook;
	
	for my $mod (sort keys %$hook) {
		$hook->{$mod}->(@args);
	}
}

sub _mod_hook {
	my($type, $lvl, @args) = @_;
	local $_;
	my $hook = $hooks{$type}{$lvl};
	return undef unless $hook;

	my $rv = undef;
	for my $mod (sort keys %$hook) {
		my $r = $hook->{$mod}->(@args);
		$rv = $r if defined $r;
	}
	$rv;
}

sub _send {
	my $act = $_[0];
	my @to;
	if (exists $act->{sendto} && ref $act->{sendto}) {
		@to = @{$act->{sendto}};
	} elsif (!ref $act->{dst}) {
		warn "Action $act of type $act->{type} does not have a destination or sendto list";
		return;
	} elsif ($act->{dst}->isa('Network')) {
		@to = $act->{dst};
	} else {
		@to = $act->{dst}->sendto($act);
	}
	my(%real, %jlink);
		# hash to remove duplicates
	for my $net (@to) {
		my $ij = $net->jlink();
		if (defined $ij) {
			$jlink{$ij->id()} = $ij;
		} else {
			$real{$net->id()} = $net;
		}
	}
	if ($act->{except}) {
		my $id = $act->{except}->id();
		delete $real{$id};
		delete $jlink{$id};
	}
	unless ($act->{nojlink}) {
		for my $ij (values %jlink) {
			$ij->ij_send($act);
		}
	}
	for my $net (values %real) {
		$net->send($act);
	}
}

sub _runq {
	my $q = shift;
	for my $act (@$q) {
		unshift @qstack, [];
		_run($act);
		_runq(shift @qstack);
	}
}

sub _run {
	my $act = $_[0];
	if (_mod_hook($act->{type}, check => $act)) {
		print "Check hook stole $act->{type}\n";
		return;
	}
	_hook($act->{type}, act => $act);
	$ij_testlink->ij_send($act);
	_send($act);
	_hook($act->{type}, cleanup => $act);
}

sub insert {
	for my $act (@_) {
		_run($act);
	}
}

sub insert_full {
	for my $act (@_) {
		unshift @qstack, [];
		_run($act);
		_runq(shift @qstack);
	}
}

sub append {
	push @{$qstack[0]}, @_;
}

sub err_jmsg {
	my $dst = shift;
	local $_;
	for (@_) { 
		print "$_\n";
		append(+{
			type => 'MSG',
			src => $interface,
			dst => $dst,
			msgtype => ($dst->isa('Channel') ? 1 : 2), # channel notice == annoying
			msg => $_,
		});
	}
}
	

sub jmsg {
	my $dst = shift;
	local $_;
	append(map +{
		type => 'MSG',
		src => $interface,
		dst => $dst,
		msgtype => ($dst->isa('Channel') ? 1 : 2), # channel notice == annoying
		msg => $_,
	}, @_);
}

sub schedule {
	for my $event (@_) {
		my $t = time;
		$t = $event->{time} if $event->{time} && $event->{time} > $t;
		$t += $event->{repeat} if $event->{repeat};
		$t += $event->{delay} if $event->{delay};
		push @{$tqueue{$t}}, $event;
	}
}

sub in_socket {
	my($src,$line) = @_;
	my @act = $src->parse($line);
	my $parse_hook = $src->isa('Network');
	for my $act (@act) {
		$act->{except} = $src unless $act->{except};
		unshift @qstack, [];
		if ($parse_hook) {
			unless (_mod_hook($act->{type}, parse => $act)) {
				_run($act);
			}
		} else {
			_run($act);
		}
		_runq(shift @qstack);
	}
} 

sub timer {
	my $now = time;
	return if $now == $last_check;
	my @q;
	for ($last_check .. $now) {
		# yes it will hit some times twice... that is needed if events with delay=0 are
		# added to the queue in the same second, but after the queue has already run
		push @q, @{delete $tqueue{$_}} if exists $tqueue{$_};
	}
	$last_check = $now;
	for my $event (@q) {
		unshift @qstack, [];
		$event->{code}->($event);
		_runq(shift @qstack);
		if ($event->{repeat}) {
			my $t = $now + $event->{repeat};
			push @{$tqueue{$t}}, $event;
		}
	}
}

sub in_newsock {
	my($sock,$peer) = @_;
	my($port,$addr) = unpack_sockaddr_in6($peer);
	print "Incoming connection $addr:$port\n";
	# TODO
}

sub command_add {
	for my $h (@_) {
		my $cmd = $h->{cmd};
		die "Cannot double-add command '$cmd'" if exists $commands{$cmd};
		$commands{$cmd} = $h;
	}
}

sub in_command {
	my($cmd, $nick, $text) = @_;
	my $csub = exists $commands{$cmd} ?
		$commands{$cmd}{code} : $commands{unk}{code};
	unshift @qstack, [];
	$csub->($nick, $text);
	_runq(shift @qstack);
}

sub link {
	my($net,$sock) = @_;
	my $id = $net->id();
	$nets{$id} = $net;

	unshift @qstack, [];
	_run(+{
		type => 'NETLINK',
		net => $net,
		sendto => [ values %nets ],
	});
	_runq(shift @qstack);
}

sub delink {
	my($net,$msg) = @_;
	my $id = $net->id();
	delete $nets{$id};
	my $q = delete $netqueues{$id};
	$q->[0] = $q->[3] = undef; # fail-fast on remaining references
	return if $net->isa('Pending');
	unshift @qstack, [];
	_run(+{
		type => 'NETSPLIT',
		net => $net,
		sendto => [ values %nets ],
		msg => $msg,
	});
	_runq(shift @qstack);
}


sub modload {
	&Janus::command_add({
		cmd => 'help',
		help => 'the text you are reading now',
		code => sub {
			my(@cmds,@helps);
			for my $cmd (sort keys %commands) {
				my $h = $commands{$cmd}{help};
				next unless $h;
				push @cmds, $cmd;
				if (ref $h) {
					push @helps, @$h;
				} else {
					push @helps, " $cmd - $h";
				}
			}
			&Janus::jmsg($_[0], 'Available commands: '.join(' ', @cmds), @helps);
		}
	});
}

1;
