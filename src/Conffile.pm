# Copyright (C) 2007-2009 Daniel De Graaf
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
&Janus::static(qw(netconf));

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
			/^([a-zA-Z][-0-9a-zA-Z_]{0,7})( |$)/ or do {
				&Log::err("Invalid network ID '$1' in line $. of config file");
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
			$current = undef unless /{/;
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
		} elsif ($newconf{set}{name} !~ /^[a-zA-Z][-0-9a-zA-Z_]{0,7}$/) {
			&Log::err("Invalid server name $newconf{set}{name}");
			return;
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
	return if $Snapshot::preread;

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
			&Log::err("Invalid module name (* must refer to an entire directory)");
			next;
		}
		my $sysdir = 'src/'.$moddir;
		$sysdir =~ s#::#/#g;
		my $dir;
		unless (opendir $dir, $sysdir) {
			&Log::err("Could not search directory $moddir: $!");
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
		unless (&Janus::load($mod)) {
			&Log::err("Could not load module $mod: $@");
		}
	}

	unless (@loggers) {
		require Log::Debug;
		push @loggers, $Log::Debug::INST;
	}
	if (!$^P || $RemoteJanus::self) { # first load on a debug run skips this
		@Log::listeners = @loggers;
		&Log::dump_queue();
	}
}

sub find_ssl_keys {
	my($net,$lnet) = @_;
	my $nconf = $Conffile::netconf{ref $net ? $net->id : $net};
	my $lconf = $lnet ? $Conffile::netconf{$lnet->id} : undef;
	my $sconf = $Conffile::netconf{set};
	return undef unless $nconf->{linktype} =~ /ssl/;
	return ($nconf->{ssl_keyfile}, $nconf->{ssl_certfile}) if $nconf->{ssl_certfile};
	return ($lconf->{keyfile}, $lconf->{certfile}) if $lconf && $lconf->{certfile};
	return ($sconf->{ssl_keyfile}, $sconf->{ssl_certfile}) if $sconf->{ssl_certfile};
	&Log::warn_in($net, 'Could not find SSL certificates') if $lnet;
	return ('client',undef);
}

sub connect_net {
	my($nick,$id) = @_;
	my $nconf = $netconf{$id};
	return if !$nconf || $Janus::nets{$id} || $Janus::ijnets{$id} || $Janus::pending{$id};
	if ($id =~ /^LISTEN:/) {
		return if $Listener::open{$id};
		my $list = Listener->new(id => $id, conf => $nconf);
		my $addr;
		my $port = $nconf->{addr};
		if ($port =~ /^(.*):(\d+)/) {
			($addr,$port) = ($1,$2);
		}
		if (&Connection::init_listen($list,$addr,$port)) {
			&Log::info("Listening on $nconf->{addr}");
		} else {
			&Log::err("Could not listen on port $nconf->{addr}: $!");
			$list->close();
		}
	} elsif ($nconf->{autoconnect}) {
		&Log::info("Autoconnecting $id");
		my $type = 'Server::'.$nconf->{type};
		unless (&Janus::load($type)) {
			&Log::err("Error creating $type network $id: $@");
		} else {
			&Log::info("Setting up nonblocking connection to $nconf->{netname} at $nconf->{linkaddr}:$nconf->{linkport}");

			my($addr, $port, $bind) = @$nconf{qw(linkaddr linkport linkbind)};
			my($ssl_key, $ssl_cert) = find_ssl_keys($id);

			my $net = &Persist::new($type, id => $id);
			# this is equivalent to $type->new(id => \$id) but without using eval

			&Connection::init_connection($net, $addr, $port, $bind, $ssl_key, $ssl_cert);
			$Janus::pending{$id} = $net;
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
		&Connection::drop_socket($net);
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

our($saveevent, $autoevent);
$saveevent->{code} = \&Conffile::save if $saveevent;
$autoevent->{code} = \&Conffile::autoconnect if $autoevent;

&Event::hook_add(
	REHASH => act => sub {
		my $act = shift;
		&Conffile::rehash($act->{src});
	},
	'INITCONF' => act => sub {
		my $act = shift;
		$conffile = $act->{file};
		read_conf;
	},
	RESTORE => act => sub {
		@Log::listeners = ();
		&Conffile::rehash();
	},
	RUN => act => sub {
		my $save = $netconf{set}{save};
		if ($save && -f $save) {
			$save = './'.$save unless $save =~ m#^/#;
			do $save;
		}
		connect_net undef,$_ for keys %netconf;
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
		&Event::schedule($autoevent, $saveevent);
	},
);

1;
