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
		unless ($nick->has_mode('oper') || $pass eq $Conffile::netconf{set}{pass}) {
			&Janus::jmsg($nick, "You must be an IRC operator or specify the rehash password to use this command");
			return;
		}
		&Janus::append(+{
			src => $nick,
			type => 'REHASH',
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
		&Connection::abort();
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
		for my $itm (keys %Connection::queues) {
			my $net = $Connection::queues{$itm}[3];
			if (ref $net && $net->isa('Listener')) {
				delete $Connection::queues{$itm};
			}
		}
		# the I/O queue could possibly be empty by now; add an item to force it to stay around
		$Connection::queues{RESTARTER} = [ undef, undef, undef, undef, 0, 0 ];
		# sechedule the actual exec at a later time to try to send the restart netsplit message around
		&Janus::schedule(+{
			delay => 2,
			code => sub {
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
		if ($onoff) {
			&Conffile::connect_net($nick, $id);
		}
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
		my $net = $Janus::nets{lc $_} || $Janus::ijnets{lc $_};
		return unless $net;
		if ($net->isa('LocalNetwork')) {
			&Janus::append(+{
				type => 'NETSPLIT',
				net => $net,
				msg => 'Forced split by '.$nick->homenick().' on '.$nick->homenet()->name()
			}, {
				type => 'REHASH',
				sendto => [],
			});
		} elsif ($net->isa('Server::InterJanus')) {
			&Janus::append(+{
				type => 'JNETSPLIT',
				net => $net,
				msg => 'Forced split by '.$nick->homenick().' on '.$nick->homenet()->name()
			}, {
				type => 'REHASH',
				sendto => [],
			});
		}
	},
}, {
	cmd => 'list',
	help => 'Shows a list of the linked networks and shared channels',
	code => sub {
		my $nick = shift;
		my $hnet = $nick->homenet();
		my $amsg = 'Linked Networks:';
		my $head = join ' ', grep !($_ eq 'janus' || $_ eq $hnet->name()), sort keys %Janus::nets;
		my %chans;
		my $len = length($amsg) - 1;
		for my $chan ($hnet->all_chans()) {
			my @nets = $chan->nets();
			next if @nets == 1;
			my @list;
			my $hname = lc $chan->str($hnet);
			for my $net (@nets) {
				next if $net eq $hnet;
				my $oname = lc $chan->str($net);
				push @list, $net->name().($hname eq $oname ? '' : $oname);
			}
			$len = length $hname if length $hname > $len;
			$chans{$hname} = join ' ', sort @list;
		}
		&Janus::jmsg($nick, sprintf '%-'.($len+1).'s %s', $amsg, $head);
		&Janus::jmsg($nick, map {
			sprintf " %-${len}s \%s", $_, $chans{$_};
		} sort keys %chans);
	}
});

1;
