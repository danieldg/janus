# Copyright (C) 2007-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Janus;
use strict;
use warnings;
use Carp 'cluck';
use Scalar::Util 'weaken';

# set only on released versions
our $RELEASE;

=head1 Janus

Module loader/unloader, global variable namespace

=head2 Public variables

=over

=item $Janus::time

Current server timestamp, used to avoid calls to time() and to prevent time from jumping during an
event.

=item $Janus::global

Message target which sends to all servers

=item %Janus::nets

Map of network tag to network object

=item %Janus::ijnets

Map of interjanus tag to interjanus network object

=item %Janus::pending

Map of network tag to (unsynchronized) network object

=item %Janus::gnets

Map of network gid to network object

=item %Janus::gnicks

Map of nick gid to nick object

=item %Janus::gchans

Map of channel keyname to channel object. This is only used in link mode,
and only for channels that are shared.

=item %Janus::chans

Map of channel name to channel object. This is only used in bridge mode.

=item $Janus::lmode

Either "link" or "bridge" depending on the link mode.

=item %Janus::modinfo

Map of module name to module information hash.

=back

=cut

# PUBLIC VARS
our $time;       # Current server timestamp, used to avoid extra calls to time()
our $global;     # Message target: ALL servers, everywhere
$time ||= time;

our %nets;       # by network tag
our %ijnets;     # by name (ij tag)
our %pending;    # by network tag
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
our %static;
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

our $git_revcache;
our $git_cachets = 0;

sub git_revid {
	return $git_revcache if $git_cachets == $Janus::time;
	$git_cachets = $Janus::time;
	my $raw_cid = `git rev-parse --verify HEAD 2>/dev/null`;
	if ($raw_cid) {
		if (`git describe --tags` =~ /^v(.*)/) {
			$git_revcache = $1;
			$git_revcache =~ s/-g(....).*/-$1/;
		} else {
			$git_revcache = 'g'.substr $raw_cid, 0, 8;
		}
	} else {
		$git_revcache = undef;
	}
	return $git_revcache;
}

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
	my $git = git_revid();
	if ($git) {
		my $tree = `git ls-tree HEAD $fn`;
		my $file = `git diff-index HEAD $fn`;
		if ($tree && !$file) {
			$ver = $git;
		}
	}
	if ($RELEASE && $rel_csum{$fn} && $rel_csum{$fn} eq $csum) {
		$ver = $RELEASE;
	}
	$modinfo{$mod}{version} = $ver;
	$fn =~ s#^src/##;
	$INC{$fn} = $ver.'/'.$fn;
}

=head2 Module load commands

=over

=item Janus::reload(modulename)

Load or reload the given module. Returns true if successful

=item Janus::load(modulename)

Load the given module (does nothing if the module is already loaded).
Return true if the module is loaded

=item Janus::unload(modulename)

Removes all hooks registered by the given module

=cut

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

Marks the given variables for state saving and restoring. Must be called in module init

=cut

sub save_vars {
	my $class = caller || 'Janus';
	cluck "Janus::save_vars called outside module load" unless $modinfo{$class}{load};
	$states{$class} = { @_ };
}

=item Janus::info(%info)

Provides information about the module. Must be called in module init

=cut

sub info {
	my $class = caller || 'Janus';
	cluck "Janus::info called outside module load" unless $modinfo{$class}{load};
	my %add = @_;
	for (qw(desc)) {
		next unless exists $add{$_};
		$modinfo{$class}{$_} = delete $add{$_};
	}
	cluck "Ignoring unknown info keys for $class" if scalar %add;
}

sub static {
	my $pkg = caller;
	for my $var (@_) {
		$static{$pkg.'::'.$var}++;
	}
}

=back

=cut

unless ($global) {
	# first-time run
	my $two = 2;
	$global = bless \$two;
	unshift @INC, $global;
	csum_read('Janus');
	_load_run('Event');
}

Janus::info(desc => 'Core module loader');
Janus::static(qw(global new_sha1 static modinfo));

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
		delete $act->{except} if $act->{except} && $net == $act->{except};
		$gnets{$net->gid()} = $net;
		delete $pending{$id};
		$nets{$id} = $net;
	}, NETSPLIT => parse => sub {
		my $act = shift;
		my $net = $act->{net};
		if ($act->{except} && $act->{except}->isa('RemoteJanus')) {
			delete $act->{netsplit_quit};
			return 1 unless $net && $act->{except}->jparent($net->jlink());
		} else {
			&Log::info('Network '.$net->name.' split: '.$act->{msg});
		}
		undef;
	}, NETSPLIT => act => sub {
		my $act = shift;
		my $net = $act->{net};
		my $id = $net->name();
		delete $gnets{$net->gid()};
		delete $nets{$id};
		delete $pending{$id};
	}, JNETLINK => act => sub {
		my $act = shift;
		my $net = $act->{net};
		my $id = $net->id();
		delete $pending{$id};
		$ijnets{$id} = $net;
	}, JNETSPLIT => act => sub {
		my $act = shift;
		my $net = $act->{net};
		delete $ijnets{$net->id};
		delete $pending{$net->id};
		my @alljnets = values %ijnets;
		for my $snet (@alljnets) {
			next unless $snet->parent() && $net eq $snet->parent();
			&Event::insert_full(+{
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
			&Event::insert_full(+{
				type => 'NETSPLIT',
				net => $snet,
				msg => $act->{msg},
				netsplit_quit => 1,
				nojlink => 1,
			});
		}
	}, POISON => parse => sub {
		my $act = shift;
		weaken($act->{item});
		if ('Persist::Poison' eq ref $act->{item}) {
			$act->{item} = undef;
		}
		return 1 unless $act->{item};
		0;
	}, POISON => cleanup => sub {
		my $act = shift;
		if ($act->{item}) {
			&Persist::poison($act->{item});
		}
	},
);

sub gid {
	'*';
}

sub jmsg { goto &Interface::jmsg }

# finalize Janus.pm loading
if ($modinfo{Janus}{load} == 1) {
	# initial load, must finalize ourself
	delete $modinfo{Janus}{load};
	$modinfo{Janus}{active} = 1;
	_load_run('Log');
	_load_run('EventDump');
}

1;
