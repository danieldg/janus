# Copyright (C) 2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Replay;
use strict;
use warnings;
use integer;
use Scalar::Util 'blessed';

# reconstructed
our($gnicks, $gchans, $gnets, $ijnets, $state, $listen, $global, $object, $arg);

our(%obj_db, $thaw_var, $thaw_fd);

sub regobj {
	for my $o (@_) {
		next unless $o && blessed($o);
		my $class = ref $o;
		$obj_db{$class}{$$o} = $o;
	}
}

sub findobj {
	my($o, $class) = @_;
	return bless($o,$class) unless 'SCALAR' eq ref $o && $$o;
	my $c = $obj_db{$class}{$$o};
	$c || bless($o,$class);
}

$thaw_var = sub {
	my($class, $var) = @_;
	$Persist::vars{$class}{$var};
};

$thaw_fd = sub {
	1;
};

sub zero { 0 }

sub run {
	my($conf, $dump) = @_;
	&Janus::insert_full({
		type => 'INIT',
		args => [ '', $conf ]
	});

	%Conffile::inet = (
		type => 'DUMP-REPLAY',
		listn => \&zero,
		conn => \&zero,
		addr => sub { 'nowhere', 5 },
	);

	for (values %Conffile::netconf) {
		$_->{autoconnect} = 0;
		&Janus::load('Server::'.$_->{type}) if $_->{type};
	}

	&Janus::insert_full({ type => 'RUN' });

	regobj %Janus::gnicks, %Janus::gnets, $Janus::global, $RemoteJanus::self;

	do $dump;

	for my $var (keys %$global) {
		my $val = $global->{$var};
		no strict 'refs';
		$var =~ s/^(.)//;
		if ($1 eq '$') {
			${$var} = $val;
		} elsif ($1 eq '@') {
			@{$var} = @$val;
		} elsif ($1 eq '%') {
			%{$var} = %$val;
		} else {
			die "Unknown global variable type $1$var";
		}
	}

	for my $pkg (keys %$object) {
		for my $oid (keys %{$object->{$pkg}}) {
			for my $var (keys %{$object->{$pkg}{$oid}}) {
				$Persist::vars{$pkg}{$var}[$oid] = $object->{$pkg}{$oid}{$var};
			}
		}
	}

	for my $mod (sort keys %Janus::modules) {
		&Janus::reload($mod);
		&Janus::unload($mod) unless $global->{'%Janus::modules'}{$mod};
	}

	my $save = $Conffile::netconf{set}{save};
	if ($save && -f $save) {
		$save = './'.$save unless $save =~ m#^/#;
		do $save;
	}

	&Log::debug("Beginning debug deallocations");

	%obj_db = ();
	($gnicks, $gchans, $gnets, $ijnets, $state, $listen, $global, $object, $arg) =
		(undef, undef, undef,  undef,   undef,  undef,   undef,   undef,  undef);
	@Connection::queues = grep { $_->[&Connection::NET] } @Connection::queues;

	&Log::debug("State restored. Beginning replay.");
}

&Event::hook_add(
	NETSPLIT => act => sub {
		my $act = shift;
		my $net = $act->{net};

		my $q = &Connection::del($net);
		return if $net->jlink();

		warn "Queue for network $$net was already removed" unless $q;
	}, JNETSPLIT => check => sub {
		my $act = shift;
		my $net = $act->{net};

		my $q = &Connection::del($net);
		warn "Queue for network $$net was already removed" unless $q;

		my $eq = $Janus::ijnets{$net->id()};
		return 1 if $eq && $eq ne $net;
		undef;
	}
);


package Connection;

our @queues;

sub NET { 0 }
sub PINGT { 1 }

sub add {
	push @queues, [ $_[1], 0 ];
}

sub init_listen {
	1;
}

sub init_conn {
	1;
}

sub del {
	my $net = shift;
	for (0..$#queues) {
		next unless $queues[$_][NET] == $net;
		splice @queues, $_, 1;
		return 1;
	}
	0;
}

1;
