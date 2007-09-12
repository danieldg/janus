# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Janus;
use strict;
use warnings;
use Carp 'cluck';

our($VERSION) = '$Rev$' =~ /(\d+)/;

=head1 Janus

Primary event multiplexer and module loader/unloader

=cut

# PUBLIC VARS
our $interface;

our %nets;
our %ijnets;
our %gnicks;
our %gchans;

=head2 Module loading

=over

=item Janus::load($module, @args)

Loads a module from a file, allowing it to register hooks as it loads and
registering it for unloading

=item Janus::unload($module)

Remove hooks and commands for a module. This is called automatically when your module
is unladed or reloaded

=item Janus::reload($module, @args)

Same as calling unload and load sequentially

=cut

# module => state (0 = unloaded, 1 = loading, 2 = loaded)
our %modules;
$modules{Janus} = 1;

our %hooks;
our %commands;

sub reload {
	my $module = $_[0];

	&Janus::unload if $modules{$module};
	&Janus::load;
}

sub load {
	my $module = shift;
	return 1 if $modules{$module};

	$modules{$module} = 1;

	my $fn = $module.'.pm';
	$fn =~ s#::#/#g;
	if (-f $fn && do $fn) {
		$modules{$module} = 2;
	} else {
		warn "Cannot load module $module: $! $@";
		$modules{$module} = 0;
	}
}

sub unload {
	my $module = $_[0];

	for my $t (keys %hooks) {
		for my $l (keys %{$hooks{$t}}) {
			delete $hooks{$t}{$l}{$module};
		}
	}
	for my $cmd (keys %commands) {
		next unless $commands{$cmd}{class} eq $module;
		delete $commands{$cmd};
	}

	$modules{$module} = 0;
}

sub update_versions {
	$_[0] =~ /([0-9A-Za-z_:]+)/;
	my $mod = $1;
	my $fn = $mod.'.pm';
	$fn =~ s#::#/#g;
	return unless -f $fn;
	my $ver = '?';
	my $sha = `sha1sum $fn 2>/dev/null`;
	if ($sha && $sha =~ /^(.{8})/) {
		$ver = 'x'.$1;
		no strict 'refs';
		no warnings 'once';
		${$mod.'::SHA_UID'} = $1;
	} else {
		$sha = `sha1 $fn 2>/dev/null`;
		if ($sha =~ / = (.{8})/) {
			$ver = 'x'.$1;
			no strict 'refs';
			no warnings 'once';
			${$mod.'::SHA_UID'} = $1;
		} else {
			warn "Cannot checksum module $mod";
		}
	}
	my $git = `git rev-parse --verify HEAD 2>/dev/null`;
	if ($git) {
		unless (`git diff-index HEAD $fn`) {
			# this file is not modified from the current head
			`git rev-parse HEAD` =~ /^(.{8})/;
			$ver = 'g'.$1;
			# ok, we have the ugly name... now look for a tag
			`git name-rev --tags --name-only HEAD` =~ /^(.*?)(?:^0)?$/;
			my $tag = $1;
			if ($tag ne 'undefined' && $tag !~ /~/) {
				# we are actually on this tag
				$ver = 't'.$tag;
			}
		}
	}
	my $svn = `svn info $fn 2>/dev/null`;
	if ($svn) {
		unless (`svn st $fn`) {
			if ($svn =~ /Revision: (\d+)/) {
				$ver = 'r'.$1;
			} else {
				warn "Cannot parse `svn info` output for $mod ($fn)";
			}
		}
	}
	no strict 'refs';
	no warnings 'once';
	${$mod.'::VERSION_NAME'} = $ver;
}

update_versions 'Janus';

sub Janus::INC {
	my($self, $name) = @_;
	open my $rv, '<', $name or return undef;
	my $module = $name;
	$module =~ s/.pm$//;
	$module =~ s#/#::#g;
	&Janus::update_versions($module);
	$modules{$module} = 1;
	&Janus::schedule({ code => sub {
		$modules{$module} = 2;
	}});
	$rv;
}

BEGIN {
	our $INC_ITEM;
	unless ($INC_ITEM) {
		my $dummy = 1;
		$INC_ITEM = bless \$dummy;
		unshift @INC, $INC_ITEM;
	}
}

=back

=cut

our $last_check = time;

# TODO this should really be maintained by main with an interface of some kind to add/remove
# entries
# (net | port number) => [ sock, recvq, sendq, (Net | undef if listening), trying_read, trying_write ]
our %netqueues;

$commands{unk} = +{
	class => 'Janus',
	code => sub {
		&Janus::jmsg($_[0], 'Unknown command. Use "help" to see available commands');
	},
};

our @qstack;
our %tqueue;

=head2 Action Hooks

The given coderef will be called with a single argument, the action hashref

Hooks, in order of execution:
  parse - possible reparse point (/msg janus *) - only for local origin
  jparse - possible reparse point - only for interjanus origin

  validate - make sure arguments are the proper type etc, to avoid crashes
    type for the validate hook is 'ALL' rather than the given type

  check - reject unauthorized and/or impossible commands
  act - Main state processing
  send (not a hook) - event is sent to local and remote networks
  cleanup - Reference deletion

validate, parse, jparse, and check hooks should return one of the tribool values:
  undef if the action was not modified
  0 if the action was modified (to detect duplicate hooks)
  1 if the action was rejected (should be dropped)

act and cleanup hooks ignore the return values. The action
hashref itself should NEVER be modified in these hooks

=over

=item Janus::hook_add([type, level, coderef]+)

Add hooks for a module. Should be called from module init

=cut

sub hook_add {
	my $module = caller;
	cluck "hook_add called outside module load" unless $modules{$module} == 1;
	while (@_) {
		my ($type, $level, $sub) = (shift, shift, shift);
		warn unless $sub;
		$hooks{$type}{$level}{$module} = $sub;
	}
}

=item Janus::command_add($cmdhash+)

Add commands (/msg janus <command> <cmdargs>). Should be called from module init

Command hashref contains:
	cmd - command name
	code - will be executed with two arguments: ($nick, $cmdargs)

=cut

sub command_add {
	my $class = caller || 'Janus';
	cluck "command_add called outside module load" unless $modules{$class} == 1;
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

=back

=cut

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
	&EventDump::debug_send($act);
	my @to;
	if (exists $act->{sendto} && ref $act->{sendto}) {
		@to = @{$act->{sendto}};
	} elsif ($act->{type} =~ /^NET(LINK|SPLIT)/) {
		@to = (values(%nets), values %ijnets);
		for my $q (values %netqueues) {
			my $net = $$q[3];
			next unless defined $net;
			push @to, $net if $net->isa('Server::InterJanus');
		}
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
	if (_mod_hook('ALL', validate => $act)) {
		my $err = $@ || 'unknown error';
		$err =~ s/\n//;
		print "Validate hook [$err] on";
		&EventDump::debug_send($act);
		return;
	}
	if (_mod_hook($act->{type}, check => $act)) {
		print "Check hook stole";
		&EventDump::debug_send($act);
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

=item Janus::jmsg($dst, $msg,...)

Send the given message(s), sourced from the janus interface,
to the given destination

=cut

sub jmsg {
	my $dst = shift;
	return unless $dst;
	local $_;
	&Janus::append(map +{
		type => 'MSG',
		src => $interface,
		dst => $dst,
		msgtype => ($dst->isa('Channel') ? 'PRIVMSG' : 'NOTICE'), # channel notice == annoying
		msg => $_,
	}, @_);
}

=item Janus::err_jmsg($dst, $msg,...)

Send error messages to the given destination and to standard error

=cut

sub err_jmsg {
	my $dst = shift;
	local $_;
	for (@_) { 
		print STDERR "$_\n";
		next unless $dst;
		&Janus::append(+{
			type => 'MSG',
			src => $interface,
			dst => $dst,
			msgtype => ($dst->isa('Channel') ? 'PRIVMSG' : 'NOTICE'), # channel notice == annoying
			msg => $_,
		});
	}
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
		my $t = time;
		$t = $event->{time} if $event->{time} && $event->{time} > $t;
		$t += $event->{repeat} if $event->{repeat};
		$t += $event->{delay} if $event->{delay};
		push @{$tqueue{$t}}, $event;
	}
}

sub in_socket {
	my($src,$line) = @_;
	return unless $src;
	my @act = $src->parse($line);
	my $parse_hook = $src->isa('Network');
	for my $act (@act) {
		$act->{except} = $src unless exists $act->{except};
		unshift @qstack, [];
		unless (_mod_hook($act->{type}, ($parse_hook ? 'parse' : 'jparse'), $act)) {
			_run($act);
		}
		_runq(shift @qstack);
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

sub link {
	my $net = shift;
	&Janus::insert_full(+{
		type => 'NETLINK',
		net => $net,
	});
}

sub delink {
	my($net,$msg) = @_;
	if ($net->isa('Pending')) {
		my $id = $net->id();
		delete $nets{$id};
		delete $netqueues{$id};
	} elsif ($net->isa('Server::InterJanus')) {
		my $id = $net->id();
		delete $ijnets{$id};
		my $q = delete $netqueues{$id};
		$q->[0] = $q->[3] = undef; # fail-fast on remaining references
		for my $snet (values %nets) {
			next unless $snet->jlink() && $id eq $snet->jlink()->id();
			&Janus::insert_full(+{
				type => 'NETSPLIT',
				net => $snet,
				msg => $msg,
			});
		}
	} else {
		&Janus::insert_full(+{
			type => 'NETSPLIT',
			net => $net,
			msg => $msg,
		});
	}
}

=back

=cut

&Janus::hook_add(
	NETLINK => act => sub {
		my $act = shift;
		my $net = $act->{net};
		my $id = $net->id();
		$nets{$id} = $net;
	}, NETSPLIT => act => sub {
		my $act = shift;
		my $net = $act->{net};
		my $id = $net->id();
		delete $nets{$id};
		my $q = delete $netqueues{$id};
		$q->[0] = $q->[3] = undef; # fail-fast on remaining references
	},
);
&Janus::command_add({
	cmd => 'help',
	help => 'the text you are reading now',
	code => sub {
		my($nick,$arg) = @_;
		if ($arg) {
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
			my $synlen = 0;
			for my $cmd (sort keys %commands) {
				my $h = $commands{$cmd}{help};
				next unless $h;
				push @cmds, $cmd;
				$synlen = length $cmd if length $cmd > $synlen;
			}
			&Janus::jmsg($nick, 'Available commands: ');
			&Janus::jmsg($nick, map {
				sprintf " \002\%-${synlen}s\002  \%s", uc $_, $commands{$_}{help};
			} @cmds);
		}
	},
});

$modules{Janus} = 2;

# we load these modules down here because their loading uses
# some of the subs defined above
use EventDump;

1;
