# Copyright (C) 2007-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Conffile;
use strict;
use warnings;
use integer;
use Listener;
use RemoteJanus;
use Data::Dumper;

our $conffile;
our %netconf;
Janus::static(qw(netconf));

sub read_conf {
	local $_;
	my %newconf;
	my $current;
	$conffile ||= 'janus.conf';
	open my $conf, '<', $conffile or do {
		Log::err("Could not open configuration file: $!");
		return;
	};
	while (<$conf>) {
		chomp;
		s/\s*$//;
		next if /^\s*(#|$)/;
		s/^\s*(\S+)\s*(.*)// or die;
		my $type = $1;
		$_ = $2; # untaint

		if ($type eq 'link') {
			if (defined $current) {
				Log::err("Missing closing brace at line $. of config file, aborting");
				return;
			}
			/^(\S+)/ or do {
				Log::err("Error in line $. of config file: expected network ID");
				return;
			};
			/^([a-zA-Z][-0-9a-zA-Z_]{0,7})( |$)/ or do {
				Log::err("Invalid network ID '$1' in line $. of config file");
				return;
			};
			$current = { id => $1 };
			$newconf{$1} = $current;
		} elsif ($type eq 'listen') {
			if (defined $current) {
				Log::err("Missing closing brace at line $. of config file, aborting");
				return;
			}
			/^((?:\S+:)?\d+)( |$)/ or do {
				Log::err("Error in line $. of config file: expected port or IP:port");
				return;
			};
			$current = { addr => $1 };
			$newconf{'LISTEN:'.$1} = $current;
			$current = undef unless /{/;
		} elsif ($type eq 'log') {
			if (defined $current) {
				Log::err("Missing closing brace at line $. of config file, aborting");
				return;
			}
			/^(\S+)(?: |$)/ or do {
				Log::err("Error in line $. of config file: expected log name");
				return;
			};
			$newconf{'LOG:'.$1} = $current = { name => $1 };
		} elsif ($type eq 'set' || $type eq 'modules') {
			if (defined $current) {
				Log::err("Missing closing brace at line $. of config file, aborting");
				return;
			}
			$current = {};
			$newconf{$type} = $current;
		} elsif ($type eq '}') {
			unless (defined $current) {
				Log::err("Extra closing brace at line $. of config file");
				return;
			}
			$current = undef;
		} elsif ($type eq '{') {
		} else {
			unless (defined $current) {
				Log::err("Error in line $. of config file: not in a network definition");
				return;
			}
			$current->{$type} = $_;
		}
	}
	close $conf;
	if ($newconf{set}{name}) {
		if ($RemoteJanus::self) {
			Log::err("You must restart the server to change the name")
				if $RemoteJanus::self->id() ne $newconf{set}{name};
			$newconf{set}{name} = $RemoteJanus::self->id();
		} elsif ($newconf{set}{name} !~ /^[a-zA-Z][-0-9a-zA-Z_]{0,7}$/) {
			Log::err("Invalid server name $newconf{set}{name}");
			return;
		}
	} else {
		Log::err("Server name not set! You need set block with a 'name' entry");
		return;
	}
	unless ($Janus::lmode) {
		my $mode = lc $newconf{set}{lmode} || 'link';
		if ($mode eq 'link') {
			Janus::load('Link');
		} elsif ($mode eq 'bridge') {
			Janus::load('Bridge');
		} else {
			Log::err("Bad value $mode for set::lmode");
			return;
		}
	}
	return if $Snapshot::preread;

	my %pre_loggers = map { $_->name, $_ } @Log::listeners;
	my @loggers;
	for my $id (keys %newconf) {
		next unless $id =~ /LOG:(.*)/;
		my $log = $newconf{$id};
		my $type = 'Log::'.$log->{type};
		Janus::load($type) or do {
			Log::err("Could not load module $type: $@");
			next;
		};
		my $name = $log->{name};
		if ($pre_loggers{$name} && $type eq ref $pre_loggers{$name}) {
			my $running = delete $pre_loggers{$name};
			$running->reconfigure($log) if $running->can('reconfigure');
			push @loggers, $running;
		} else {
			push @loggers, $type->new(%$log);
		}
	}
	$newconf{modules}{$_}++ for qw(Interface Actions Account Setting Commands::Core);
	my @stars = grep /\*/, keys %{$newconf{modules}};
	for my $moddir (@stars) {
		delete $newconf{modules}{$moddir};
		if ($moddir !~ s/::\*(?:\.pm)?$//) {
			Log::err("Invalid module name (* must refer to an entire directory)");
			next;
		}
		my $sysdir = 'src/'.$moddir;
		$sysdir =~ s#::#/#g;
		my $dir;
		unless (opendir $dir, $sysdir) {
			Log::err("Could not search directory $moddir: $!");
			next;
		}
		while ($_ = readdir $dir) {
			s/\.pm$// or next;
			/^([0-9a-zA-Z_]+)$/ or warn "Bad filename $_";
			$newconf{modules}{$moddir.'::'.$1}++;
		}
		closedir $dir;
	}

	%netconf = %newconf;

	for my $mod (sort keys %{$newconf{modules}}) {
		unless (Janus::load($mod)) {
			Log::err("Could not load module $mod: $@");
		}
	}

	unless (@loggers) {
		require Log::Debug;
		push @loggers, $Log::Debug::INST;
	}
	if (!$^P || $RemoteJanus::self) { # first load on a debug run skips this
		@Log::listeners = @loggers;
		Log::dump_queue();
	}
}

sub value {
	my($key, $net, $fbid) = @_;
	my $nc =
		'HASH' eq ref $net ? $net :
		ref $net ? $Conffile::netconf{$net->id} :
		$Conffile::netconf{$net};
	return undef unless $nc;
	return $nc->{$key} if $nc->{$key};
	unless ($fbid) {
		$fbid = $nc->{fb_id} || 0;
		my $fbmax = $nc->{fb_max};
		unless ($fbmax) {
			$fbmax = 1;
			for (keys %$nc) {
				$fbmax = $1 if /\.(\d+)$/ && $fbmax < $1;
			}
			$nc->{fb_max} = $fbmax;
		}
		$fbid = 1 + ($fbid % $fbmax);
	}
	$nc->{"$key.$fbid"};
}

sub find_ssl_keys {
	my($net,$lnet) = @_;
	return () unless value(linktype => $net) eq 'ssl';
	return (value(ssl_keyfile => $net), value(ssl_certfile => $net), value(ssl_cafile => $net)) if value(ssl_certfile => $net);
	return (value(keyfile => $lnet), value(certfile => $lnet), value(cafile => $lnet)) if $lnet && value(certfile => $lnet);
	return (value(ssl_keyfile => 'set'), value(ssl_certfile => 'set'), value(ssl_cafile => 'set')) if value(ssl_certfile => 'set');
	Log::warn_in($net, 'Could not find SSL certificates') if $lnet;
	return ('client', '', '');
}

sub connect_net {
	my($id) = @_;
	return if !$netconf{$id} || $Janus::nets{$id} || $Janus::ijnets{$id} || $Janus::pending{$id};
	if ($id =~ /^LISTEN:/) {
		return if $Listener::open{$id};
		my $list = Listener->new(id => $id, conf => $netconf{$id});
		my $addr;
		my $port = value(addr => $id);
		Log::info("Accepting incoming connections on $port");
		if ($port =~ /^(.*):(\d+)/) {
			($addr,$port) = ($1,$2);
		}
		Connection::init_listen($list,$addr,$port);
	} elsif ($netconf{$id}{autoconnect}) {
		Log::info("Autoconnecting $id");
		my $type = 'Server::'.value(type => $id);
		unless (Janus::load($type)) {
			Log::err("Error creating $type network $id: $@");
		} else {
			my $name = value(netname => $id);
			my $addr = value(linkaddr => $id);
			my $port = value(linkport => $id);
			my $bind = value(linkbind => $id);
			Log::info("Setting up nonblocking connection to $name at $addr:$port");

			my($ssl_key, $ssl_cert, $ssl_ca) = find_ssl_keys($id);

			my $net = Persist::new($type, id => $id);
			# this is equivalent to $type->new(id => \$id) but without using eval

			Connection::init_connection($net, $addr, $port, $bind, $ssl_key, $ssl_cert, $ssl_ca);
			$Janus::pending{$id} = $net;
			$net->intro($Conffile::netconf{$id});
		}
	}
}

sub rehash {
	read_conf;
	my %toclose = %Listener::open;
	delete $toclose{$_} for keys %netconf;
	for my $net (values %toclose) {
		$net->delink();
	}
	connect_net $_ for keys %netconf;
}

sub autoconnect {
	my $act = shift;
	$act->{repeat} = 15 + int rand 45;
	for my $id (keys %netconf) {
		if ($id =~ /^LISTEN/) {
			connect_net $id unless $Listener::open{$id};
		} elsif (!$netconf{$id}{autoconnect} || exists $Janus::nets{$id} || exists $Janus::ijnets{$id}) {
			$netconf{$id}{backoff} = 0;
			$netconf{$id}{fb_id} = 0;
		} elsif ($netconf{$id}{fb_id} < $netconf{$id}{backoff}) {
			$netconf{$id}{backoff} = 0;
			$netconf{$id}{fb_id}++;
			connect_net $id;
		} else {
			$netconf{$id}{backoff}++;
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
			$val = $val->() if 'CODE' eq ref $val;
			push @vars, $val;
			push @refs, '*'.$class.'::'.$var;
		}
	}
	open my $f, '>', $out or return 0;
	my $d = Data::Dumper->new(\@vars, \@refs);
	$d->Purity(1)->Toaster('thaw');
	print $f $d->Dump;
	close $f;
	return 1;
}

our($saveevent, $autoevent);
$saveevent->{code} = \&Conffile::save if $saveevent;
$autoevent->{code} = \&Conffile::autoconnect if $autoevent;

Event::hook_add(
	REHASH => act => sub {
		my $act = shift;
		Conffile::rehash();
	},
	'INITCONF' => act => sub {
		my $act = shift;
		$conffile = $act->{file};
		read_conf;
	},
	RESTORE => act => sub {
		@Log::listeners = ();
		Conffile::rehash();
	},
	RUN => act => sub {
		my $save = $netconf{set}{save};
		if ($save && -f $save) {
			$save = './'.$save unless $save =~ m#^/#;
			do $save;
		}
		connect_net $_ for keys %netconf;
		$autoevent = {
			repeat => 30,
			code => \&Conffile::autoconnect,
			desc => 'autoconnect',
		};
		$saveevent = {
			repeat => 3600,
			code => \&Conffile::save,
			desc => 'autosave',
		};
		Event::schedule($autoevent, $saveevent);
	},
);

1;
