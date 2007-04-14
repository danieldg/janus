package Janus;
use strict;
use warnings;
use InterJanus;
use Unreal;
use IO::Select;

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

our $conffile;
our $interface;
our %nets;
our $read = IO::Select->new();
my %hooks;
my @qstack;

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
	my $taken;
	
	for my $mod (sort keys %$hook) {
		my $r = $hook->{$mod}->(@args);
		if (defined $r) {
			warn "Multiple modifying hooks found for $type:$lvl ($taken, $mod)" if $taken;
			$taken = $mod;
			$rv = $r;
		}
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

sub link {
	my $net = $_[0];
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
	my $net = $_[0];
	my $id = $net->id();
	delete $nets{$id};
	unshift @qstack, [];
	_run(+{
		type => 'NETSPLIT',
		net => $net,
		sendto => [ values %nets ],
	});
	_runq(shift @qstack);
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

sub jmsg {
	my $dst = shift;
	local $_;
	append(map +{
		type => 'MSG',
		src => $interface,
		dst => $dst,
		notice => !$dst->isa('Channel'), # channel notice == annoying
		msg => $_,
	}, @_);
}

sub in_local {
	my($src,@act) = @_;
	for my $act (@act) {
		$act->{except} = $src unless $act->{except};
		unshift @qstack, [];
		if (_mod_hook($act->{type}, parse => $act)) {
			print "Parse hook stole $act->{type}\n";
		} else {
			_run($act);
		}
		_runq(shift @qstack);
	}
}

sub in_janus {
	for my $act (@_) {
		unshift @qstack, [];
		_run($act);
		_runq(shift @qstack);
	}
} 


###############################################################################
# Configuration
###############################################################################

sub rehash {
	local $_;
	my($net,$nconf);
	open my $conf, '<', $conffile;
	$conf->untaint(); 
		# the configurator is assumed to have at least half a brain :)
	while (<$conf>) {
		chomp;
		s/\s*$//;
		next if /^\s*(#|$)/;
		s/^\s*(\S+)\s*// or do {
			print "Error in line $. of config file\n";
			next;
		};
		my $type = lc $1;

		if ($type eq 'unreal') {
			if (defined $net) {
				print "Missing closing brace at line $. of config file\n";
			}
			/^(\S+)/ or do {
				print "Error in line $. of config file: expected network ID\n";
				next;
			};
			my $netid = $1;
			$net = $nets{$netid};
			unless (defined $net && $net->isa('Unreal')) {
				print "Creating new net $netid\n";
				$net = Unreal->new( id => $netid );
			}
			$nconf = {};
		} elsif ($type eq '}') {
			unless (defined $net) {
				print "Extra closing brace at line $. of config file\n";
				next;
			}
			$net->configure($nconf);
			unless (exists $nets{$net->id()}) {
				print "Connecting to $nconf->{netname}\n";
				my $sock = $net->connect();
				if ($sock) {
					Janus::link($net);
					$read->add([$sock, '', '', $net]);
				} else {
					print "Cannot connect to $net->{id}\n";
				}
			}
			$net = undef;
		} elsif ($type eq '{') {
		} else {
			unless (defined $net) {
				print "Error in line $. of config file: not in a network definition\n";
				next;
			}
			$nconf->{$type} = $_;
		}
	}
	close $conf;
}

sub modload {
 my($class,$cfile) = @_;
 $conffile = $cfile;
 hook_add($class,
	REHASH => act => sub {
		rehash;
	}, LINKED => act => sub {
		my $act = shift;
		my $net = $act->{net};
		if ($net->id() eq 't1') {
			insert_full(+{
				type => 'LINKREQ',
				net => $net,
				dst => $nets{t2},
				slink => '#opers',
				dlink => '#test',
			});
		} elsif ($net->id() eq 't2') {
			insert_full(+{
				type => 'LINKREQ',
				net => $net,
				dst => $nets{t1},
				slink => '#test',
				dlink => '#opers',
			});
		} 
	});
}

1;
