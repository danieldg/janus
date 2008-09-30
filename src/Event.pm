# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Event;
use strict;
use warnings;
use Carp 'cluck';

our $last_check;
$last_check ||= $Janus::time; # not assigned so that reloads don't skip seconds

our @qstack;
our %tqueue;

our %hook_mod; # $hook_mod{"$type/$level"}{$module} = $sub;

# Caches derived from hook_mod
our %hook_chk; # $hook_???{$type} => sub
our %hook_run;

our %commands;

=head1 Event

Primary event hook registration and dispatch point

=head2 Hook Registration

All hook registration must happen during a module load.

=over

=item Event::hook_add($type1, $level1, $sub1, $type2, $level2, $sub2, ...)

Registers the given subref as an event hook for the type/level specified.

For normal event hooks, $type is the name of the action; for named hooks, $type
is either "ALL" or a name specified in the name. The level can either be a simple
string of the level, or a string of the form "level:priority" where priority is
a signed decimal number. A hook with a lower priority is guarunteed to run before hooks
of higher priority; if priority is not specified, it defaults to zero.

=cut

sub hook_add {
	my $module = caller;
	cluck "hook_add called outside module load" unless $Janus::modinfo{$module}{load};
	while (@_) {
		my ($type, $level, $sub) = (shift, shift, shift);
		warn unless $sub;
		my $when = $type.'/'.$level;
		$hook_mod{$when}{$module} = $sub;
		delete $hook_chk{$type};
		delete $hook_run{$type};
		$when =~ s/:.*//;
		delete $hook_run{$when};
	}
}

=item Event::command_add($cmdhash+)

Add commands (/msg janus <command> <cmdargs>).

Command hashref contains:

  cmd - command name
  code - will be executed with the arguments: ($src, $dst, @args)
  help - help text
  details - arrayref of detailed help text, one line per elt
  acl - undef/0 for all, 1 for oper-only, 2+ to be defined later
  secret - 1 if the command should not be logged (i.e. it contains passwords)

If you set the "secret" flag, log the command in your code after stripping out sensitive information.

=cut

sub command_add {
	my $class = caller;
	cluck "command_add called outside module load" unless $Janus::modinfo{$class}{load};
	for my $h (@_) {
		my $cmd = $h->{cmd};
		if (exists $commands{$cmd}) {
			my $c = $commands{$cmd}{class};
			warn "Overriding command '$cmd' from class '$c' with one from class '$class'";
		}
		$h->{class} = $class;
		$commands{$cmd} = $h;
	}
}

sub _send {
	my $act = $_[0];
	&EventDump::debug_send($act);
	my @to;
	if (exists $act->{sendto}) {
		if ('ARRAY' eq ref $act->{sendto}) {
			@to = @{$act->{sendto}};
		} else {
			@to = $act->{sendto};
		}
	} elsif (!ref $act->{dst}) {
		# this must be an internal command, otherwise we have already complained in Actions
		return;
	} elsif ($act->{dst}->isa('Network')) {
		@to = $act->{dst};
	} else {
		@to = $act->{dst}->sendto($act);
	}
	my(%sockto); # hash to remove duplicates
	for my $net (@to) {
		next unless $net;
		if ($net == $Janus::global) {
			$sockto{$_} = $_ for values %Janus::nets;
			$sockto{$_} = $_ for values %Janus::ijnets;
			$sockto{$_} = $_ for $Interface::network;
		} elsif ($net == $RemoteJanus::self) {
			$_->jlink() or $sockto{$_} = $_ for values %Janus::nets;
		} else {
			$sockto{$net} = $net;
		}
	}
	my $again = 1;
	while ($again) {
		$again = 0;
		my @some = values %sockto;
		for my $net (@some) {
			if ($net->isa('RemoteJanus') && $net->parent()) {
				my $p = $net->parent();
				delete $sockto{$net};
				$sockto{$p} = $p;
				$again++;
			} elsif ($net->isa('Network') && $net->jlink()) {
				my $j = $net->jlink();
				delete $sockto{$net};
				$sockto{$j} = $j;
				$again++;
			}
		}
	}

	if ($act->{except} && !($act->{dst} && $act->{dst} eq $act->{except})) {
		delete $sockto{$act->{except}};
	}
	for my $net (values %sockto) {
		next if $act->{nojlink} && $net->isa('RemoteJanus');
		eval {
			$net->send($act);
			1;
		} or do {
			named_hook('die', $@, 'send', $net, $act);
		};
	}
}

$hook_mod{'ALL/send'}{Event} = \&_send;

# Finds a hook name given the subref
sub find_hook {
	my $hook = shift;
	for my $lvl (keys %hook_mod) {
		for my $mod (keys %{$hook_mod{$lvl}}) {
			my $s = $hook_mod{$lvl}{$mod};
			next unless $s eq $hook;
			return ($mod, $lvl);
		}
	}
	return 'unknown hook';
}

sub _runq {
	my $q = shift;
	for my $act (@$q) {
		unshift @qstack, [];
		_run($act);
		$act = undef;
		_runq(shift @qstack);
	}
}

# Return the properly sorted list for hooks on the given type/level
sub enum_hooks {
	my $pfx = $_[0];
	return
		map { values %{$hook_mod{$_}} }
		sort { ($a =~ /:([-0-9.]+)/ ? $1 : 0) <=> ($b =~ /:([-0-9.]+)/ ? $1 : 0) }
		grep { 0 == index $_, $pfx }
		keys %hook_mod;
}

sub _run {
	my $act = $_[0];
	my $type = $act->{type};
	my($chk,$run) = ($hook_chk{$type}, $hook_run{$type});
	unless ($chk && $run) {
		($chk, $run) = ([], []);
		
		push @$chk, enum_hooks($type . '/parse');
		push @$chk, enum_hooks('ALL/validate');
		push @$chk, enum_hooks($type . '/check');

		push @$run, enum_hooks($type . '/act');
		push @$run, \&_send;
		push @$run, enum_hooks($type . '/cleanup');

		($hook_chk{$type}, $hook_run{$type}) = ($chk,$run);
	}
	for my $h (@$chk) {
		my $rv = eval { $h->($act) };
		if ($@) {
			named_hook('die', $@, find_hook($h), $act);
		} elsif ($rv) {
			&Log::hook_info($act, "Check hook stole");
			return;
		}
	}
	for my $h (@$run) {
		eval { $h->($act) };
		if ($@) {
			named_hook('die', $@, find_hook($h), $act);
		}
	}
}

=back

=head2 Event Sending

=over

=item Event::insert_partial($action,...)

Run the given actions right now, but run any generated actions later
(use insert_full unless you need this behaviour).

=cut

sub insert_partial {
	for my $act (@_) {
		_run($act);
	}
}

=item Event::insert_full($action,...)

Fully run the given actions before returning

=cut

sub insert_full {
	for my $act (@_) {
		unshift @qstack, [];
		_run($act);
		_runq(shift @qstack);
	}
}

=item Event::append($action,...)

Run the given actions after this one is done executing

=cut

sub append {
	push @{$qstack[0]}, @_;
}

=item Event::in_socket($src,$line)

Processes the line which came from the given source network

=cut

sub in_socket {
	my($src,$line) = @_;
	return unless $src;
	eval {
		my @act = $src->parse($line);
		for my $act (@act) {
			$act->{except} = $src;
			unshift @qstack, [];
			_run($act);
			$act = undef;
			_runq(shift @qstack);
		}
		1;
	} or do {
		named_hook('die', $@, @_);
		&Log::err_in($src, "Unchecked exception in parsing");
	};
}

=item Event::in_command($src, $dst, @args)

Processes the split arguments as a command initiated by the nick $src, with results
written to the nick or channel $dst. The first argument is the command name.

=cut

sub in_command {
	my ($src, $dst, $cmd, @args) = @_;
	$cmd = lc $cmd;
	$cmd = 'unk' unless exists $commands{$cmd};
	my $csub = exists $commands{$cmd}{code} ? $commands{$cmd}{code} : $commands{unk}{code};
	my $acl = $commands{$cmd}{acl} || 0;
	if ($acl == 1 && !$src->has_mode('oper')) {
		&Janus::jmsg($dst, "You must be an IRC operator to use this command");
		return;
	}
	unless ($commands{$cmd}{secret}) {
		&Log::command(@_);
	}
	unshift @qstack, [];
	eval {
		$csub->($src, $dst, @args);
		1;
	} or do {
		named_hook('die', $@, @_);
	};
	_runq(shift @qstack);
}

=item Event::named_hook($name, @args)

Dispatches an event of the given name. The name is the "level" of the event if it
does not contain a "/"; if it contains a "/" it is of the form "type/level".

=cut

sub named_hook {
	my($name, @args) = @_;
	local $_;

	$name = 'ALL/'.$name unless $name =~ m#/#;
	my $hooks = $hook_run{$name};
	unless ($hooks) {
		$hook_run{$name} = $hooks = [];
		@$hooks = enum_hooks($name);
	}
	for my $hook (@$hooks) {
		eval {
			$hook->(@args);
			1;
		} or do {
			my @hifo = find_hook($hook);
			if ($name eq 'ALL/die') {
				&Log::err("Unchecked exception in die hook, from module $hifo[0]: $@");
			} else {
				named_hook('die', $@, @hifo, @args);
			}
		};
	}
}

=back

=head2 Time-based events

=over

=item Event::schedule(TimeEvent,...)

schedule the given events for later execution. TimeEvent is a hashref containing:

time - the unix timestamp to execute

repeat - repeat the action every N seconds (the action should remove this when it is done)

delay - to run the event once, N seconds from now

code - must be specified; subref, which is passed the event as its single argument

All other fields are available for use in passing additional arguments to the coderef

=cut

sub schedule {
	for my $event (@_) {
		my $t = $Janus::time;
		$t = $event->{time} if $event->{time} && $event->{time} > $t;
		$t += $event->{repeat} if $event->{repeat};
		$t += $event->{delay} if $event->{delay};
		push @{$tqueue{$t}}, $event;
	}
}

=item Event::timer($now)

Updates the janus time and runs timed events

=cut

sub timer {
	my $time = $_[0];
	$Janus::time = $time;
	my @q;
	if ($last_check > $time) {
		my $off = $last_check-$time;
		&Log::err("Time runs backwards! From $last_check to $time; offsetting all events by $off");
		my %oq = %tqueue;
		%tqueue = ();
		$tqueue{$_ - $off} = $oq{$_} for keys %oq;
	} elsif ($last_check < $time) {
		&Log::timestamp($time);
		for ($last_check .. $time) {
			# yes it will hit some times twice... that is needed if events with delay=0 are
			# added to the queue in the same second, but after the queue has already run
			push @q, @{delete $tqueue{$_}} if exists $tqueue{$_};
		}
	}
	$last_check = $time;
	for my $event (@q) {
		unshift @qstack, [];
		eval {
			$event->{code}->($event);
			1;
		} or do {
			named_hook('die', $@, 'timer', $event);
		};
		_runq(shift @qstack);
		if ($event->{repeat}) {
			my $t = $time + $event->{repeat};
			push @{$tqueue{$t}}, $event;
		}
	}
}

=item Event::next_event(max)

Returns the unix timestamp of the next event, if one will happen before $max when interpreted as a
timestamp.

=back

=cut

sub next_event {
	my $max = shift;
	for ($Janus::time..$max) {
		return $_ if $tqueue{$_};
	}
	$max;
}

sub wipe_hooks {
	my $module = $_[0];
	for my $hk (values %hook_mod) {
		delete $hk->{$module};
	}
	%hook_chk = ();
	%hook_run = ();
	for my $cmd (keys %commands) {
		warn "Command $cmd lacks class" unless $commands{$cmd}{class};
		next unless $commands{$cmd}{class} eq $module;
		delete $commands{$cmd};
	}
}

Event::hook_add(
	ALL => 'die' => sub {
		&Log::err(@_);
	}, MODUNLOAD => act => sub {
		wipe_hooks($_[0]->{module});
	}, MODRELOAD => 'act:-1' => sub {
		wipe_hooks($_[0]->{module});
	}
);

Event::command_add({
	cmd => 'help',
	help => 'The text you are reading now',
	code => sub {
		my($src,$dst,$item) = @_;
		$item = lc $item || '';
		if (exists $commands{lc $item}) {
			my $det = $commands{$item}{details};
			if (ref $det) {
				&Janus::jmsg($dst, @$det);
			} elsif ($commands{$item}{help}) {
				&Janus::jmsg($dst, "$item - $commands{$item}{help}");
			} else {
				&Janus::jmsg($dst, 'No help for that command');
			}
		} else {
			my @cmds;
			my $all = $src->has_mode('oper') || $item eq 'all';
			my $synlen = 0;
			for my $cmd (sort keys %commands) {
				my $h = $commands{$cmd}{help};
				next unless $h;
				next if $commands{$cmd}{acl} && !$all;
				push @cmds, $cmd;
				$synlen = length $cmd if length $cmd > $synlen;
			}
			&Janus::jmsg($dst, "Use '\002HELP\002 command' for details", 'Available commands: ');
			&Janus::jmsg($dst, map {
				sprintf " \002\%-${synlen}s\002  \%s", uc $_, $commands{$_}{help};
			} @cmds);
		}
	}
}, {
	cmd => 'unk',
	code => sub {
		&Janus::jmsg($_[1], 'Unknown command. Use "help" to see available commands');
	},
});

1;
