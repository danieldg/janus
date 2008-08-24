# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Janus;
use strict;
use warnings;
use Carp 'cluck';
use Scalar::Util 'weaken';

# set only on released versions
our $RELEASE;

=head1 Janus

Primary event multiplexer and module loader/unloader

=cut

# PUBLIC VARS
our $time;       # Current server timestamp, used to avoid extra calls to time()
our $global;     # Message target: ALL servers, everywhere
$time ||= time;

our %nets;       # by network tag
our %ijnets;     # by name (ij tag)
our %gnets;      # by guid
our %gnicks;     # by guid

our $lmode;      # Link mode: either "Link" or "Bridge"
our %gchans;     # Link:   by keyname
our %chans;      # Bridge: by name

our %modinfo;    # by module name
# load    : 1 if module is being loaded
# version : visible version of module
# active  : 1 if module is active (hooks enabled)
# sha     : sha1sum of module file
$modinfo{Janus}{load}++;

our %states;
our %rel_csum;

sub Janus::INC {
	my($self, $name) = @_;
	open my $rv, '<', 'src/'.$name or return undef;
	my $module = $name;
	$module =~ s/.pm$//;
	$module =~ s#/#::#g;
	if ($modinfo{Event}{active}) {
		Event::named_hook('module_read', $module, $rv);
	}
	csum_read($module, $rv);
	unless ($modinfo{$module}{load}) {
		$modinfo{$module}{load} = 1;
		Event::schedule({
			code => \&_load_clean,
			module => $module,
		});
	}
	$rv;
}

sub _load_clean {
	my $ev = shift;
	my $module = $ev->{module};
	delete $modinfo{$module}{load};
	$modinfo{$module}{active} = 1;
}

sub _load_run {
	my $module = $_[0];
	$modinfo{$module}{load} = 1;

	my $fn = $module.'.pm';
	$fn =~ s#::#/#g;
	unless (-f "src/$fn") {
		&Log::err("Cannot find module $module: $!");
		delete $modinfo{$module}{load};
	}
	delete $INC{$fn};
	if (require $fn) {
		delete $modinfo{$module}{load};
		$modinfo{$module}{active} = 1;
	} else {
		&Log::err("Cannot load module $module: $! $@");
		delete $modinfo{$module}{load};
	}
}

# was this checked out from somewhere?
my $has_git = (`git 2>&1`) ? 1 : 0;
my $has_svn = (`svn 2>&1`) ? 1 : 0;

if ($RELEASE) {
	open my $rcs, "src/.rel-$RELEASE" or warn "Cannot open release checksum file!";
	while (<$rcs>) {
		my($s,$f) = /^(\S{40})\s+(.*)/ or warn "bad line: $_";
		$rel_csum{$f} = $s;
	}
	close $rcs;
}

our $new_sha1;
$new_sha1 ||= eval {
	require Digest::SHA1;
	sub { Digest::SHA1->new(); }
} || eval {
	require Digest::SHA;
	sub { Digest::SHA->new('sha1'); }
} || die "One of Digest::SHA1 or Digest::SHA is required to run";

sub csum_read {
	my $mod = $_[0];
	$mod =~ /([0-9A-Za-z_:]+)/;
	my $fn = "src/$1.pm";
	$fn =~ s#::#/#g;
	my $ver = '?';

	my $sha1 = $new_sha1->();
	if ($_[1]) {
		$sha1->addfile($_[1]);
		seek $_[1], 0, 0;
	} else {
		open my $fh, '<', $fn or return;
		$sha1->addfile($fh);
		close $fh;
	}
	my $csum = $sha1->hexdigest();
	$modinfo{$mod}{sha} = $csum;
	$ver = 'x'.$1 if $csum =~ /^(.{8})/;
	if ($has_svn) {
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
	}
	if ($has_git) {
		my $git = `git rev-parse --verify HEAD 2>/dev/null`;
		if ($git) {
			unless (`git diff-index HEAD $fn`) {
				# this file is not modified from the current head
				# ok, we have the ugly name... now look for a tag
				if (`git describe --tags` =~ /^(v.*?)(?:-g[0-9a-fA-F]+)?$/) {
					$ver = $1;
				} elsif ($git =~ /^(.{8})/) {
					$ver = 'g'.$1;
				}
			}
		}
	}
	if ($RELEASE && $rel_csum{$fn} && $rel_csum{$fn} eq $csum) {
		$ver = $RELEASE;
	}
	$modinfo{$mod}{version} = $ver;
	$fn =~ s#^src/##;
	$INC{$fn} = $ver.'/'.$fn;
}

sub reload {
	my $module = $_[0];
	if ($modinfo{$module}{active}) {
		Event::insert_full({
			type => 'MODRELOAD',
			module => $_[0],
		});
		return $modinfo{$_[0]}{active};
	} else {
		goto &Janus::load;
	}
}

sub load {
	Event::insert_full({
		type => 'MODLOAD',
		module => $_[0],
	});
	$modinfo{$_[0]}{active};
}

sub unload {
	Event::insert_full({
		type => 'MODUNLOAD',
		module => $_[0],
	});
}

=item Janus::save_vars(varname => \%value, ...)

Marks the given variables for state saving and restoring.

=cut

sub save_vars {
	my $class = caller || 'Janus';
	cluck "command_add called outside module load" unless $modinfo{$class}{load};
	$states{$class} = { @_ };
}

=item Janus::info(%info)

provides information about the module (while loading)

=cut

sub info {
	my $class = caller || 'Janus';
	cluck "command_add called outside module load" unless $modinfo{$class}{load};
	my %add = @_;
	for (qw(desc)) {
		next unless exists $add{$_};
		$modinfo{$class}{$_} = delete $add{$_};
	}
	cluck "Ignoring unknown info keys for $class" if scalar %add;
}

unless ($global) {
	# first-time run
	my $two = 2;
	$global = bless \$two;
	unshift @INC, $global;
	csum_read('Janus');
	_load_run('Event');
}

Janus::info(desc => 'Core module loader');

Event::hook_add(
	MODLOAD => check => sub {
		$modinfo{$_[0]->{module}}{active};
	}, MODLOAD => act => sub {
		_load_run($_[0]->{module});
	}, MODUNLOAD => act => sub {
		my $module = $_[0]->{module};
		delete $states{$module};
		delete $modinfo{$module}{active};
	}, MODRELOAD => check => sub {
		!$modinfo{$_[0]->{module}}{active};
	}, MODRELOAD => act => sub {
		my $module = $_[0]->{module};
		delete $states{$module};
		delete $modinfo{$module}{active};
		_load_run($module);
	}, NETLINK => act => sub {
		my $act = shift;
		my $net = $act->{net};
		my $id = $net->name();
		$gnets{$net->gid()} = $net;
		$nets{$id} = $net;
	}, NETSPLIT => parse => sub {
		my $act = shift;
		if ($act->{except} && $act->{except}->isa('RemoteJanus')) {
			delete $act->{netsplit_quit};
			my $net = $act->{net};
			return 1 unless $net && $act->{except}->jparent($net->jlink());
		}
		undef;
	}, NETSPLIT => act => sub {
		my $act = shift;
		my $net = $act->{net};
		my $id = $net->name();
		delete $gnets{$net->gid()};
		delete $nets{$id};
	}, JNETLINK => act => sub {
		my $act = shift;
		my $net = $act->{net};
		my $id = $net->id();
		$ijnets{$id} = $net;
	}, JNETSPLIT => act => sub {
		my $act = shift;
		my $net = $act->{net};
		delete $ijnets{$net->id()};
		my @alljnets = values %ijnets;
		for my $snet (@alljnets) {
			next unless $snet->parent() && $net eq $snet->parent();
			&Janus::insert_full(+{
				type => 'JNETSPLIT',
				net => $snet,
				msg => $act->{msg},
				netsplit_quit => 1,
				nojlink => 1,
			});
		}
		my @allnets = values %nets;
		for my $snet (@allnets) {
			next unless $snet->jlink() && $net eq $snet->jlink();
			&Janus::insert_full(+{
				type => 'NETSPLIT',
				net => $snet,
				msg => $act->{msg},
				netsplit_quit => 1,
				nojlink => 1,
			});
		}
	}, POISON => cleanup => sub {
		my $act = shift;
		weaken($act->{item});
		if ($act->{item}) {
			&Persist::poison($act->{item});
		}
	},
);

sub gid {
	'*';
}

sub jmsg { goto &Interface::jmsg }
sub err_jmsg { goto &Log::err_jmsg }

sub hook_add { goto &Event::hook_add }
sub command_add { goto &Event::command_add }
sub insert_partial { goto &Event::insert_partial }
sub insert_full { goto &Event::insert_full }
sub append { goto &Event::append }
sub schedule { goto &Event::schedule }
sub in_socket { goto &Event::in_socket }
sub timer { goto &Event::timer }
sub next_event { goto &Event::next_event }

# finalize Janus.pm loading
if ($modinfo{Janus}{load} == 1) {
	# initial load, must finalize ourself
	delete $modinfo{Janus}{load};
	$modinfo{Janus}{active} = 1;
	_load_run('Log');
	_load_run('EventDump');
}

1;
