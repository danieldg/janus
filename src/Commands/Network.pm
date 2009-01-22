# Copyright (C) 2007-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::Network;
use strict;
use warnings;
use integer;

&Event::command_add({
	cmd => 'rehash',
	help => 'Reload the config and attempt to reconnect to split servers',
	section => 'Admin',
	acl => 'rehash',
	code => sub {
		my($src,$dst) = @_;
		&Log::audit('Rehash by '.$src->netnick);
		&Event::insert_full(+{
			type => 'REHASH',
		});
		&Janus::jmsg($dst, 'Rehashed');
	},
}, {
	cmd => 'die',
	help => "Kill the janus server; does \002NOT\002 restart it",
	section => 'Admin',
	acl => 'die',
	code => sub {
		my($src,$dst,$pass) = @_;
		return &Janus::jmsg($dst, "Specify the argument '".$RemoteJanus::self->id."' to confirm")
			unless $pass && $pass eq $RemoteJanus::self->id;
		&Conffile::save();
		&Log::audit('DIE by '.$src->netnick);
		for my $net (values %Janus::nets) {
			next if $net->jlink();
			&Event::append(+{
				type => 'NETSPLIT',
				net => $net,
				msg => 'Killed',
			});
		}
		print "Will exit in 1 second\n";
		&Event::schedule(+{
			delay => 1,
			code => sub { exit },
		});
	},
}, {
	cmd => 'restart',
	help => "Restart the janus server",
	section => 'Admin',
	acl => 'restart',
	code => sub {
		my($src,$dst,$pass) = @_;
		return &Janus::jmsg($dst, "Specify the argument '".$RemoteJanus::self->id."' to confirm")
			unless $pass && $pass eq $RemoteJanus::self->id;
		&Conffile::save();
		&Log::audit('RESTART by '.$src->netnick);
		for my $net (values %Janus::nets) {
			next if $net->jlink();
			&Event::append(+{
				type => 'NETSPLIT',
				net => $net,
				msg => 'Restarting...',
			});
		}
		# sechedule the actual exec at a later time to try to send the restart netsplit message around
		&Event::schedule(+{
			delay => 2,
			code => sub {
				my @arg = map { /(.*)/ ? $1 : () } @main::ARGV;
				exec 'perl', '-T', 'janus.pl', @arg;
			},
		});
	},
}, {
	cmd => 'autoconnect',
	help => 'Enable or disable autoconnect on a network',
	section => 'Network',
	details => [
		"Syntax: \002AUTOCONNECT\002 network [0|1]",
		"Enables or disables the automatic reconnection that janus makes to a network.",
		'A rehash will reread the value for the network from the janus configuration',
		'Without parameters, displays the current state',
	],
	acl => 'autoconnect',
	code => sub {
		my($src, $dst, $id, $onoff) = @_;
		my $nconf = $Conffile::netconf{$id} or do {
			&Janus::jmsg($dst, 'Cannot find network');
			return;
		};
		if (defined $onoff && $onoff =~ /^\d+$/) {
			&Log::audit("Autoconnect on $id ".($onoff ? 'enabled' : 'disabled').' by '.$src->netnick);
			$nconf->{autoconnect} = $onoff ? 1 : 0;
			$nconf->{backoff} = $onoff * ($onoff - 1) / 2;
			&Janus::jmsg($dst, 'Done');
		} else {
			&Janus::jmsg($dst, 'Autoconnect is '.($nconf->{autoconnect} ? 'on' : 'off').
				" for $id (backoff=$nconf->{backoff})");
		}
	},
}, {
	cmd => 'netsplit',
	help => 'Split a network and reconnect to it',
	section => 'Network',
	details => [
		"Syntax: \002NETSPLIT\002 network",
		"Disconnects the given network from janus and then rehashes to (possibly) reconnect",
	],
	acl => 'netsplit',
	code => sub {
		my($src,$dst,$net) = @_;
		$net = $Janus::nets{lc $net} || $Janus::ijnets{lc $net};
		return unless $net;
		if ($net->isa('LocalNetwork')) {
			&Log::audit("Network ".$net->name.' split by '.$src->netnick);
			&Event::append(+{
				type => 'NETSPLIT',
				net => $net,
				msg => 'Forced split by '.$src->netnick
			});
		} elsif ($net->isa('Server::InterJanus')) {
			&Log::audit("Network ".$net->id.' split by '.$src->netnick);
			&Event::append(+{
				type => 'JNETSPLIT',
				net => $net,
				msg => 'Forced split by '.$src->netnick
			});
		}
	},
}, {
	cmd => 'linked',
	help => 'Shows a list of the linked networks and channels',
	section => 'Info',
	code => sub {
		my($src,$dst) = @_;
		my $hnet = $src->homenet();
		my $hnetn = $hnet->name();
		my %chans;
		for my $chan ($hnet->all_chans()) {
			my %nets = map { $$_ => $_ } $chan->nets();
			delete $nets{$$hnet};
			delete $nets{$$Interface::network};
			next unless scalar keys %nets;
			my $cnet = $chan->homenet();
			my $cname = lc $chan->str($cnet);
			my $hname = lc $chan->str($hnet);
			my $hcol;
			my @list = ($hnetn);
			if ($hnet == $cnet) {
				$hcol = "\002$hnetn\002";
				@list = ();
			} elsif ($cname eq $hname) {
				$hcol = "\002".$cnet->name()."\002";
			} else {
				$hcol = "\002".$cnet->name()."$cname\002";
			}
			for my $net (values %nets) {
				next if $net == $hnet || $net == $cnet;
				my $oname = lc $chan->str($net);
				push @list, $net->name().($cname eq $oname ? '' : $oname);
			}
			$chans{$hname} = [ $hname, $hcol, join ' ', sort @list ];
		}
		my @table = map $chans{$_}, sort keys %chans;
		my $netlist = join ' ', grep !($_ eq 'janus' || $_ eq $hnetn), sort keys %Janus::nets;
		unshift @table, [ 'Linked Networks:', "\002$hnetn\002", $netlist ];
		&Interface::msgtable($dst, \@table);
	}
});

1;
