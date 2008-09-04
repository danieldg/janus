# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Conffile;
use IO::Handle;
use strict;
use warnings;
use integer;
use Listener;
use RemoteJanus;
use Data::Dumper;

our $conffile;
our %netconf;

sub read_conf {
	my $nick = shift;

	local $_;
	my %newconf;
	my $current;
	$conffile ||= 'janus.conf';
	open my $conf, '<', $conffile or do {
		&Log::err("Could not open configuration file: $!");
		return;
	};
	$conf->untaint();
		# the configurator is assumed to have at least half a brain :)
	while (<$conf>) {
		chomp;
		s/\s*$//;
		next if /^\s*(#|$)/;
		s/^\s*(\S+)\s*// or die;
		my $type = $1;

		if ($type eq 'link') {
			if (defined $current) {
				&Log::err("Missing closing brace at line $. of config file, aborting");
				return;
			}
			/^(\S+)/ or do {
				&Log::err("Error in line $. of config file: expected network ID");
				return;
			};

			$current = { id => $1 };
			$newconf{$1} = $current;
		} elsif ($type eq 'listen') {
			if (defined $current) {
				&Log::err("Missing closing brace at line $. of config file, aborting");
				return;
			}
			/^((?:\S+:)?\d+)( |$)/ or do {
				&Log::err("Error in line $. of config file: expected port or IP:port");
				return;
			};
			$current = { addr => $1 };
			$newconf{'LISTEN:'.$1} = $current;
		} elsif ($type eq 'log') {
			if (defined $current) {
				&Log::err("Missing closing brace at line $. of config file, aborting");
				return;
			}
			/^(\S+)(?: |$)/ or do {
				&Log::err("Error in line $. of config file: expected log name");
				return;
			};
			$newconf{'LOG:'.$1} = $current = { name => $1 };
		} elsif ($type eq 'set' || $type eq 'modules') {
			if (defined $current) {
				&Log::err("Missing closing brace at line $. of config file, aborting");
				return;
			}
			$current = {};
			$newconf{$type} = $current;
		} elsif ($type eq '}') {
			unless (defined $current) {
				&Log::err("Extra closing brace at line $. of config file");
				return;
			}
			$current = undef;
		} elsif ($type eq '{') {
		} else {
			unless (defined $current) {
				&Log::err("Error in line $. of config file: not in a network definition");
				return;
			}
			$current->{$type} = $_;
		}
	}
	close $conf;
	if ($newconf{set}{name}) {
		if ($RemoteJanus::self) {
			&Log::err("You must restart the server to change the name")
				if $RemoteJanus::self->id() ne $newconf{set}{name};
			$newconf{set}{name} = $RemoteJanus::self->id();
		}
	} else {
		&Log::err("Server name not set! You need set block with a 'name' entry");
		return;
	}
	unless ($Janus::lmode) {
		my $mode = lc $newconf{set}{lmode} || 'link';
		if ($mode eq 'link') {
			&Janus::load('Link');
		} elsif ($mode eq 'bridge') {
			&Janus::load('Bridge');
		} else {
			&Log::err("Bad value $mode for set::lmode");
			return;
		}
	}

	my %pre_loggers = map { $_->name, $_ } @Log::listeners;
	my @loggers;
	for my $id (keys %newconf) {
		next unless $id =~ /LOG:(.*)/;
		my $log = $newconf{$id};
		my $type = 'Log::'.$log->{type};
		&Janus::load($type) or do {
			&Log::err("Could not load module $type: $@");
			next;
		};
		my $name = $log->{name};
		if ($pre_loggers{$name} && $type eq ref $pre_loggers{$name}) {
			push @loggers, delete $pre_loggers{$name};
		} else {
			push @loggers, $type->new(%$log);
		}
	}
	unless (@loggers) {
		require Log::Debug;
		push @loggers, $Log::Debug::INST;
	}
	unless ($^P && !$nick) { # first load on a debug run skips this
		@Log::listeners = @loggers;
		&Log::dump_queue();
	}

	%netconf = %newconf;

	$newconf{modules}{$_}++ for qw(Interface Actions Commands::Core);
	for my $mod (sort keys %{$newconf{modules}}) {
		unless (&Janus::load($mod)) {
			&Log::err("Could not load module $mod: $@");
		}
	}
}

sub connect_net {
	my($nick,$id) = @_;
	my $nconf = $netconf{$id};
	return if !$nconf || $Janus::nets{$id} || $Janus::ijnets{$id} || $Janus::pending{$id};
	if ($id =~ /^LISTEN:/) {
		return if $Listener::open{$id};
		&Log::info("Listening on $nconf->{addr}");
		my $sock = &Connection::init_listen(
			($nconf->{addr} =~ /^(.*):(\d+)/) ? ($1, $2) : ('', $nconf->{addr})
		);
		if ($sock) {
			my $list = Listener->new(id => $id, conf => $nconf);
			&Connection::add($sock, $list);
		} else {
			&Log::err("Could not listen on port $nconf->{addr}: $!");
		}
	} elsif ($nconf->{autoconnect}) {
		&Log::info("Autoconnecting $id");
		my $type = 'Server::'.$nconf->{type};
		unless (&Janus::load($type)) {
			&Log::err("Error creating $type network $id: $@");
		} else {
			&Log::info("Setting up nonblocking connection to $nconf->{netname} at $nconf->{linkaddr}:$nconf->{linkport}");

			my($addr, $port, $bind) = @$nconf{qw(linkaddr linkport linkbind)};
			my $ssl = ($nconf->{linktype} =~ /^ssl/);

			my $sock = &Connection::init_conn($addr, $port, $bind, $ssl);
			return unless $sock;

			my $net = &Persist::new($type, id => $id);
			# this is equivalent to $type->new(id => \$id) but without using eval

			$Janus::pending{$id} = $net;

			&Connection::add($sock, $net);

			$net->intro($nconf);
		}
	}
}

sub rehash {
	my $nick = shift;
	read_conf $nick;
	my %toclose = %Listener::open;
	delete $toclose{$_} for keys %netconf;
	for my $net (values %toclose) {
		$net->close();
		&Connection::reassign($net, undef);
	}
	connect_net $nick,$_ for keys %netconf;

	&Janus::jmsg($nick,'Rehashed');
}

sub autoconnect {
	my $act = shift;
	$act->{repeat} = 15 + int rand 45;
	for my $id (keys %netconf) {
		if ($id =~ /^LISTEN/) {
			connect_net undef,$id unless $Listener::open{$id};
		} elsif (!$netconf{$id}{autoconnect} || exists $Janus::nets{$id} || exists $Janus::ijnets{$id}) {
			$netconf{$id}{backoff} = 0;
		} else {
			my $item = 2 * $netconf{$id}{backoff}++;
			my $rt = int sqrt $item;
			if ($item == $rt * ($rt + 1)) {
				&Log::debug("Backoff $id (#$item) - Connecting");
				connect_net undef,$id;
			} else {
				&Log::debug("Backoff $id: $item != ".$rt*($rt+1));
			}
		}
	}
}

sub save {
	my $out = $netconf{set}{save};
	my(@vars,@refs);
	keys %Janus::states;
	while (my($class,$vars) = each %Janus::states) {
		keys %$vars;
		while (my($var,$val) = each %$vars) {
			push @vars, $val;
			push @refs, '*'.$class.'::'.$var;
		}
	}
	open my $f, '>', $out or return 0;
	print $f Data::Dumper->Dump(\@vars, \@refs);
	close $f;
	return 1;
}

&Janus::hook_add(
	REHASH => act => sub {
		my $act = shift;
		&Conffile::rehash($act->{src});
	},
	'INITCONF' => act => sub {
		my $act = shift;
		$conffile = $act->{file};
		read_conf;
	},
	RUN => act => sub {
		my $save = $netconf{set}{save};
		if ($save && -f $save) {
			$save = './'.$save unless $save =~ m#^/#;
			do $save;
		}
		connect_net undef,$_ for keys %netconf;
		&Janus::schedule({
			repeat => 30,
			code => sub { &Conffile::autoconnect; }, # to allow reloads
			desc => 'autoconnect',
		});
	},
);

1;
