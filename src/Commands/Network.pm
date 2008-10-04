# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::Network;
use strict;
use warnings;

&Janus::command_add({
	cmd => 'rehash',
	help => 'Reload the config and attempt to reconnect to split servers',
	section => 'Admin',
	code => sub {
		my($src,$dst,$pass) = @_;
		unless (&Account::acl_check($src, 'oper') || &Account::acl_check($src,'rehash') ||
				$pass eq $Conffile::netconf{set}{rehashpass}) {
			&Janus::jmsg($dst, "You must be an IRC operator or specify the rehash password to use this command");
			return;
		}
		&Log::audit('Rehash by '.$src->netnick);
		&Janus::append(+{
			src => $src,
			type => 'REHASH',
		});
	},
}, {
	cmd => 'die',
	help => "Kill the janus server; does \002NOT\002 restart it",
	section => 'Admin',
	acl => 'die',
	code => sub {
		my($src,$dst,$pass) = @_;
		&Conffile::save();
		&Log::audit('DIE by '.$src->netnick);
		for my $net (values %Janus::nets) {
			next if $net->jlink();
			&Janus::append(+{
				type => 'NETSPLIT',
				net => $net,
				msg => 'Killed',
			});
		}
		print "Will exit in 1 second\n";
		&Janus::schedule(+{
			delay => 1,
			code => sub { exit },
		});
	},
}, {
	cmd => 'restart',
	help => "Restart the janus server",
	section => 'Admin',
	acl => 'die',
	code => sub {
		my($src,$dst,$pass) = @_;
		&Log::audit('RESTART by '.$src->netnick);
		&Conffile::save();
		for my $net (values %Janus::nets) {
			next if $net->jlink();
			&Janus::append(+{
				type => 'NETSPLIT',
				net => $net,
				msg => 'Restarting...',
			});
		}
		# sechedule the actual exec at a later time to try to send the restart netsplit message around
		&Janus::schedule(+{
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
	acl => 1,
	code => sub {
		my($src, $dst, $id, $onoff) = @_;
		my $nconf = $Conffile::netconf{$id} or do {
			&Janus::jmsg($dst, 'Cannot find network');
			return;
		};
		if (defined $onoff) {
			&Log::audit("Autoconnect on $id ".($onoff ? 'enabled' : 'disabled').' by '.$src->netnick);
			$nconf->{autoconnect} = $onoff;
			$nconf->{backoff} = 0;
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
	acl => 1,
	code => sub {
		my($src,$dst,$net) = @_;
		$net = $Janus::nets{lc $net} || $Janus::ijnets{lc $net};
		return unless $net;
		&Log::audit("Network ".$net->name.' split by '.$src->netnick);
		if ($net->isa('LocalNetwork')) {
			&Janus::append(+{
				type => 'NETSPLIT',
				net => $net,
				msg => 'Forced split by '.$src->netnick
			});
		} elsif ($net->isa('Server::InterJanus')) {
			&Janus::append(+{
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
		my $head1 = 'Linked Networks:';
		my $head2 = "\002$hnetn\002";
		my $head3 = join ' ', grep !($_ eq 'janus' || $_ eq $hnetn), sort keys %Janus::nets;
		my %chans;
		my $len1 = length($head1) - 1;
		my $len2 = length($head2);
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
				$len2 = length $hcol if length $hcol > $len2;
			} else {
				$hcol = "\002".$cnet->name()."$cname\002";
			}
			for my $net (values %nets) {
				next if $net == $hnet || $net == $cnet;
				my $oname = lc $chan->str($net);
				push @list, $net->name().($cname eq $oname ? '' : $oname);
			}
			$len1 = length $hname if length $hname > $len1;
			$chans{$hname} = [ $hname, $hcol, join ' ', sort @list ];
		}
		&Janus::jmsg($dst, sprintf '%-'.($len1+1).'s %-'.$len2.'s %s', $head1, $head2, $head3);
		&Janus::jmsg($dst, map {
			sprintf " \%-${len1}s \%-${len2}s \%s", @{$chans{$_}};
		} sort keys %chans);
	}
});

1;
