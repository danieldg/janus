# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Commands::Network;
use strict;
use warnings;
our($VERSION) = '$Rev$' =~ /(\d+)/;

&Janus::command_add({
	cmd => 'rehash',
	help => 'Reload the config and attempt to reconnect to split servers',
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
	help => "Kill the janus server; does \002NOT\002 restart it",
	details => [
		"Syntax: \002DIE\002 diepass",
	],
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
				msg => 'Killed',
			});
		}
		%Janus::netqueues = ();
		print "Trying to die!\n";
	},
}, {
	cmd => 'restart',
	help => "Restart the janus server",
	details => [
		"Syntax: \002RESTART\002 diepass",
	],
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
	help => 'Enable or disable autoconnect on a network',
	details => [
		"Syntax: \002AUTOCONNECT\002 network [0|1]",
		"Enables or disables the automatic reconnection that janus makes to a network.",
		"A rehash will reread the value for the network from the janus configuration",
	],
	code => sub {
		my($nick, $args) = @_;
		return &Janus::jmsg($nick, "You must be an IRC operator to use this command") unless $nick->has_mode('oper');
		my($id, $onoff) = ($args =~ /(\S+) (\d)/) or do {
			&Janus::jmsg($nick, "Syntax: \002AUTOCONNECT\002 network [0|1]");
			return;
		};
		my $nconf = $Conffile::netconf{$id} or do {
			&Janus::jmsg($nick, 'Cannot find network');
			return;
		};
		$nconf->{autoconnect} = $onoff;
		&Janus::jmsg($nick, 'Done');
	},
}, {
	cmd => 'netsplit',
	help => 'Split a network and reconnect to it',
	details => [
		"Syntax: \002NETSPLIT\002 network",
		"Disconnects the given network from janus and then rehashes to (possibly) reconnect",
	],
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
});

1;
