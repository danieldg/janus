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


our %hooks;
#our %hook_mod; # $hook_mod{$type}{$level}{$module} = $sub;

#our %hook_chk; # $hooks{$type} => [ sub, ..., sub ]
#our %hook_run;

our %commands;

sub hook_add {
	my $module = caller;
	cluck "hook_add called outside module load" unless $Janus::modinfo{$module}{load};
	while (@_) {
		my ($type, $level, $sub) = (shift, shift, shift);
		warn unless $sub;
		$hooks{$type}{$level}{$module} = $sub;
#		delete $hook_chk{$type};
#		delete $hook_run{$type};
	}
}

=item Janus::command_add($cmdhash+)

Add commands (/msg janus <command> <cmdargs>). Should be called from module init

Command hashref contains:

  cmd - command name
  code - will be executed with two arguments: ($nick, $cmdargs)
  help - help text
  details - arrayref of detailed help text, one line per elt
  acl - undef/0 for all, 1 for oper-only, 2+ to be defined later

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

sub _hook {
	my($type, $lvl, @args) = @_;
	local $_;
	my $hook = $hooks{$type}{$lvl};
	return unless $hook;

	my @hookmods = sort keys %$hook;
	for my $mod (@hookmods) {
		eval {
			$hook->{$mod}->(@args);
			1;
		} or do {
			my $err = $@;
			unless ($lvl eq 'die') {
				_hook(ALL => 'die', $mod, $lvl, $err, @args);
			}
			&Janus::err_jmsg(undef, "Unchecked exception in $lvl hook of $type, from module $mod: $err");
		};
	}
}

sub _mod_hook {
	my($type, $lvl, @args) = @_;
	local $_;
	my $hook = $hooks{$type}{$lvl};
	return undef unless $hook;

	my $rv = undef;
	for my $mod (sort keys %$hook) {
		eval {
			my $r = $hook->{$mod}->(@args);
			$rv = $r if $r;
			1;
		} or do {
			my $err = $@;
			unless ($lvl eq 'die') {
				_hook(ALL => 'die', $mod, $lvl, $err, @args);
			}
			&Janus::err_jmsg(undef, "Unchecked exception in $lvl hook of $type, from module $mod: $err");
		};
	}
	$rv;
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
			_hook(ALL => 'die', 'send', $@, $net, $act);
		};
	}
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

sub _run {
	my $act = $_[0];
	if (_mod_hook('ALL', validate => $act)) {
		my $err = $act->{ERR} || 'unknown error';
		$err =~ s/\n//;
		&Debug::hook_err($act, "Validate hook [$err]");
		return;
	}
	if (_mod_hook($act->{type}, check => $act)) {
		&Debug::hook_info($act, "Check hook stole");
		return;
	}
	_hook($act->{type}, act => $act);
	_send($act);
	_hook($act->{type}, cleanup => $act);
}

=head2 Command generation

=over

=item Janus::insert_partial($action,...)

Run the given actions right now, but run any generated actions later
(use insert_full unless you need this behaviour)

=cut

sub insert_partial {
	for my $act (@_) {
		_run($act);
	}
}

=item Janus::insert_full($action,...)

Fully run the given actions (including generated ones) before returning

=cut

sub insert_full {
	for my $act (@_) {
		unshift @qstack, [];
		_run($act);
		_runq(shift @qstack);
	}
}

=item Janus::append($action,...)

Run the given actions after this one is done executing

=cut

sub append {
	push @{$qstack[0]}, @_;
}

=item Janus::schedule(TimeEvent,...)

schedule the given events for later execution

specify {time} as the time to execute

specify {repeat} to repeat the action every N seconds (the action should remove this when it is done)

specify {delay} to run the event once, N seconds from now

{code} is the subref, which is passed the event as its single argument

All other fields are available for use in passing additional arguments to the sub

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

sub in_socket {
	my($src,$line) = @_;
	return unless $src;
	eval {
		my @act = $src->parse($line);
		my $parse_hook = $src->isa('Network') ? 'parse' : 'jparse';
		for my $act (@act) {
			$act->{except} = $src unless exists $act->{except};
			unshift @qstack, [];
			unless (_mod_hook($act->{type}, $parse_hook, $act)) {
				_run($act);
			} else {
				&Debug::hook_info($act, "$parse_hook hook stole");
			}
			$act = undef;
			_runq(shift @qstack);
		}
		1;
	} or do {
		_hook(ALL => 'die', $@, @_);
		&Janus::err_jmsg(undef, "Unchecked exception in parsing");
	};
}

sub in_command {
	my($cmd, $nick, $text) = @_;
	$cmd = 'unk' unless exists $commands{$cmd};
	my $csub = exists $commands{$cmd}{code} ? $commands{$cmd}{code} : $commands{unk}{code};
	my $acl = $commands{$cmd}{acl} || 0;
	if ($acl == 1 && !$nick->has_mode('oper')) {
		&Janus::jmsg($nick, "You must be an IRC operator to use this command");
		return;
	}
	unshift @qstack, [];
	eval {
		$csub->($nick, $text);
		1;
	} or do {
		_hook(ALL => 'die', $@, @_);
		&Janus::err_jmsg(undef, "Unchecked exception in janus command '$cmd'");
	};
	_runq(shift @qstack);
}

sub named_hook {
	# TODO
}

sub timer {
	my $time = $_[0];
	$Janus::time = $time;
	my @q;
	if ($last_check > $time) {
		my $off = $last_check-$time;
		&Debug::err("Time runs backwards! From $last_check to $time; offsetting all events by $off");
		my %oq = %tqueue;
		%tqueue = ();
		$tqueue{$_ - $off} = $oq{$_} for keys %oq;
	} elsif ($last_check < $time) {
		&Debug::timestamp($time);
		for ($last_check .. $time) {
			# yes it will hit some times twice... that is needed if events with delay=0 are
			# added to the queue in the same second, but after the queue has already run
			push @q, @{delete $tqueue{$_}} if exists $tqueue{$_};
		}
	}
	$last_check = $time;
	for my $event (@q) {
		unshift @qstack, [];
		$event->{code}->($event);
		_runq(shift @qstack);
		if ($event->{repeat}) {
			my $t = $time + $event->{repeat};
			push @{$tqueue{$t}}, $event;
		}
	}
}

sub next_event {
	my $max = shift;
	for ($Janus::time..$max) {
		return $_ if $tqueue{$_};
	}
	$max;
}

Event::hook_add(
	MODUNLOAD => act => sub {
		my $module = $_[0]->{module};
		for my $t (keys %hooks) {
			for my $l (keys %{$hooks{$t}}) {
				delete $hooks{$t}{$l}{$module};
			}
		}
		for my $cmd (keys %commands) {
			warn "Command $cmd lacks class" unless $commands{$cmd}{class};
			next unless $commands{$cmd}{class} eq $module;
			delete $commands{$cmd};
		}
	}
);

Event::command_add({
	cmd => 'help',
	help => 'The text you are reading now',
	code => sub {
		my($nick,$arg) = @_;
		if ($arg && $arg =~ /(\S+)/ && exists $commands{lc $1}) {
			$arg = lc $1;
			my $det = $commands{$arg}{details};
			if (ref $det) {
				&Janus::jmsg($nick, @$det);
			} elsif ($commands{$arg}{help}) {
				&Janus::jmsg($nick, "$arg - $commands{$arg}{help}");
			} else {
				&Janus::jmsg($nick, 'No help for that command');
			}
		} else {
			my @cmds;
			my $all = $nick->has_mode('oper') || ($arg && lc $arg eq 'all');
			my $synlen = 0;
			for my $cmd (sort keys %commands) {
				my $h = $commands{$cmd}{help};
				next unless $h;
				next if $commands{$cmd}{acl} && !$all;
				push @cmds, $cmd;
				$synlen = length $cmd if length $cmd > $synlen;
			}
			&Janus::jmsg($nick, 'Available commands: ');
			&Janus::jmsg($nick, map {
				sprintf " \002\%-${synlen}s\002  \%s", uc $_, $commands{$_}{help};
			} @cmds);
		}
	}
}, {
	cmd => 'unk',
	code => sub {
		&Janus::jmsg($_[0], 'Unknown command. Use "help" to see available commands');
	},
});

1;
