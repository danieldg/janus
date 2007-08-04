# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Interface;
BEGIN { 
	&Janus::load('Network'); 
	&Janus::load('Nick');
}
use Object::InsideOut qw(Network);
use Persist;
use strict;
use warnings;
our($VERSION) = '$Rev$' =~ /(\d+)/;

__CODE__

my $inick = $Conffile::netconf{janus}{janus} || 'janus';

if ($Janus::interface) {
	# we are being live-reloaded as a module. Don't recreate 
	# the network or nick, just reload commands
	print "Reloading Interface\n";
	if ($inick ne $Janus::interface->homenick()) {
		&Janus::insert_full(+{
			type => 'NICK',
			dst => $Janus::interface,
			nick => $inick,
			nickts => 100000000,
		});
	}
	Interface->new(id => '__reloader__');
} else {
	my $int = Interface->new(
		id => 'janus',
	);
	$int->_set_netname('Janus');
	&Janus::link($int);

	$Janus::interface = Nick->new(
		net => $int,
		nick => $inick,
		ts => 100000000,
		info => {
			ident => 'janus',
			host => 'services.janus',
			vhost => 'services',
			name => 'Janus Control Interface',
			opertype => 'Janus Service',
			_is_janus => 1,
		},
		mode => { oper => 1, service => 1, bot => 1 },
	);
}

&Janus::hook_add(
	LINKED => act => sub {
		my $act = shift;
		my $net = $act->{net};
		return if $net->jlink();
		&Janus::append(+{
			type => 'CONNECT',
			dst => $Janus::interface,
			net => $net,
		});
	}, NETSPLIT => act => sub {
		my $act = shift;
		# TODO is this needed on all nicks?
		$Janus::interface->_netpart($act->{net});
	}, MSG => parse => sub {
		my $act = shift;
		my $src = $act->{src};
		my $dst = $act->{dst};
		my $type = $act->{msgtype};
		
		return undef unless $src->isa('Nick') && $dst->isa('Nick');
		if ($dst->info('_is_janus')) {
			return 1 unless $act->{msgtype} eq 'PRIVMSG' && $src;
			local $_ = $act->{msg};
			my $cmd = s/^\s*(\S+)\s*// ? lc $1 : 'unk';
			&Janus::in_command($cmd, $src, $_);
			return 1;
		}
		
		undef;
	},
);
&Janus::command_add({
	cmd => 'info',
	help => 'provides information about janus, including a link to the complete source code',
	code => sub {
		my $nick = shift;
		&Janus::jmsg($nick, 
			'Janus is a server that allows IRC networks to share certain channels to other',
			'linked networks without needing to share all channels and make all users visible',
			'across both networks. If configured to allow it, users can also share their own',
			'channels across any linked network.',
			'-------------------------',
			'The source code can be found at http://danieldegraaf.afraid.org/janus/trunk/',
			'This file was checked out from the $URL$ $Rev$;',
			'the rest of the project may be at a later revision within this respository.',
			'If you make any modifications to this software, you must change these URLs',
			'to one which allows downloading the version of the code you are running.'
		);
	}
}, {
	cmd => 'modules',
	help => 'Version information on all modules loaded by janus',
	code => sub {
		my $nick = shift;
		opendir my $dir, '.' or return warn $!;
		&Janus::jmsg($nick, 'Janus socket core:'.$main::VERSION);
		for my $itm (sort readdir $dir) {
			next unless $itm =~ /^([0-9_A-Za-z]+)\.pm$/;
			my $mod = $1;
			no strict 'refs';
			my $v = ${$mod.'::VERSION'};
			next unless $v; # not loaded
			&Janus::jmsg($nick, "$mod:$v");
		}
		closedir $dir;
	}
}, {
	cmd => 'rehash',
	help => 'reload the config and attempt to reconnect to split servers',
	code => sub {
		my($nick,$pass) = @_;
		unless ($nick->has_mode('oper') || $pass eq $Conffile::netconf{janus}{pass}) {
			&Janus::jmsg($nick, "You must be an IRC operator or specify the rehash password to use this command");
			return;
		}
		&Janus::append(+{
			src => $nick,
			type => 'REHASH',
			sendto => [],
		});
	},
}, {
	cmd => 'die',
	help => "kill the janus server; does \002NOT\002 restart it",
	code => sub {
		my($nick,$pass) = @_;
		unless ($nick->has_mode('oper') && $pass && $pass eq $Conffile::netconf{janus}{diepass}) {
			&Janus::jmsg($nick, "You must be an IRC operator and specify the 'diepass' password to use this command");
			return;
		}
		exit;
	},
}, {
	cmd => 'restart',
	help => "restart the janus server",
	code => sub {
		my($nick,$pass) = @_;
		unless ($nick->has_mode('oper') && $pass && $pass eq $Conffile::netconf{janus}{diepass}) {
			&Janus::jmsg($nick, "You must be an IRC operator and specify the 'diepass' password to use this command");
			return;
		}
		for my $net (values %Janus::nets) {
			next if $net->jlink();
			&Janus::append(+{
				type => 'NETSPLIT',
				net => $net,
				msg => 'Restarting...',
			});
		}
		# Clean up all non-LocalNetwork items in the I/O queue
		for my $itm (keys %Janus::netqueues) {
			my $net = $Janus::netqueues{$itm}[3];
			unless (ref $net && $net->isa('LocalNetwork')) {
				delete $Janus::netqueues{$itm};
			}
		}
		# the I/O queue could possibly be empty by now; add an item to force it to stay around
		$Janus::netqueues{RESTARTER} = [ undef, undef, undef, undef, 0, 0 ];
		# sechedule the actual exec at a later time to try to send the restart netsplit message around
		&Janus::schedule(+{
			delay => 2,
			code => sub {
				$ENV{PATH} = '/usr/bin';
				exec 'perl -T janus.pl';
			},
		});
	},
}, {
	cmd => 'autoconnect',
	help => 'autoconnect $net 1|0 - enable or disable autoconnect on a network',
	code => sub {
		my($nick, $args) = @_;
		return &Janus::jmsg($nick, "You must be an IRC operator to use this command") unless $nick->has_mode('oper');
		my($id, $onoff) = ($args =~ /(\S+) (\d)/) or warn;
		my $nconf = $Conffile::netconf{$id} or do {
			&Janus::jmsg($nick, 'Cannot find network');
			return;
		};
		$nconf->{autoconnect} = $onoff;
		&Janus::jmsg($nick, 'Done');
	},
}, {
	cmd => 'netsplit',
	help => 'netsplit $net - cause a network split and automatic rehash',
	code => sub {
		my $nick = shift;
		return &Janus::jmsg($nick, "You must be an IRC operator to use this command") unless $nick->has_mode('oper');
		my $net = $Janus::nets{lc $_} or return;
		return if $net->jlink();
		&Janus::append(+{
			type => 'NETSPLIT',
			net => $net,
			msg => 'Forced split by '.$nick->homenick().' on '.$nick->homenet()->id()
		}, {
			type => 'REHASH',
			sendto => [],
		});
	},
}, {
	cmd => 'reload',
	help => "reload \$module - load or reload a module, live. \002EXPERIMENTAL\002. ".
		'Reloading core modules may introduce bugs because of persistance of old code by the perl interpreter',
	code => sub {
		my($nick,$name) = @_;
		return &Janus::jmsg($nick, "You must be an IRC operator to use this command") unless $nick->has_mode('oper');
		return &Janus::jmsg($nick, "Invalid module name") unless $name =~ /^([0-9_A-Za-z]+)$/;
		my $n = $1;
		if (&Janus::reload($n)) {
			&Janus::err_jmsg($nick, "Module reloaded");
		} else {
			&Janus::err_jmsg($nick, "Module load failed: $@");
		}
	},
}, {
	cmd => 'chatops',
	help => 'chatops $msg - send a messge to opers on all other networks (if enabled, this is done by /chatops)',
	code => sub {
		my($nick,$msg) = @_;
		return &Janus::jmsg($nick, "You must be an IRC operator to use this command") unless $nick->has_mode('oper');
		&Janus::append(+{
			type => 'CHATOPS',
			src => $nick,
			sendto => [ values %Janus::nets ],
			msg => $msg,
		});
	},
}, {
	cmd => 'chatto',
	help => 'chatto $netid $msg - send a message to all opers on a specific network',
	code => sub {
		my($nick,$msg) = @_;
		return &Janus::jmsg($nick, "You must be an IRC operator to use this command") unless $nick->has_mode('oper');
		$msg =~ s/^(\S+) // or return;
		my $net = $Janus::nets{$1} or return;
		&Janus::append(+{
			type => 'CHATOPS',
			src => $nick,
			dst => $net,
			msg => $msg,
		});
	},
});

sub parse { () }
sub send { }
sub request_nick { $_[2] }
sub release_nick { }
sub all_nicks { $Janus::interface }
sub all_chans { () }

1;
