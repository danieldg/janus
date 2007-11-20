# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Commands::Verify;
use strict;
use warnings;

our($VERSION) = '$Rev$' =~ /(\d+)/;

&Janus::command_add({
	cmd => 'verify',
	code => sub {
		my($nick,$tryfix) = @_;
		return &Janus::jmsg($nick, "You must be an IRC operator to use this command") unless $nick->has_mode('oper');
		my $ts = time;
		my @fixes;
		open my $dump, '>', "log/verify-$ts" or return;
		for my $nick (values %Janus::gnicks) {
			my $hn = $nick->homenick();
			my $ht = $nick->homenet() or do {
				print $dump "nick $$nick has null homenet\n";
				next;
			};
			for my $net ($nick->netlist()) {
				my $rf = $Janus::gnets{$net->gid()};
				if (!$rf || $rf ne $net) {
					push @fixes, +{
						type => 'KILL',
						dst => $nick,
						net => $net,
						msg => 'Please rejoin | Fixing internal corruption',
					};
					print $dump "nick $$nick on dropped network $$net\n";
				} else {
					$rf = $Janus::nets{$net->name()};
					if (!$rf || $rf ne $net) {
						print $dump "nick $$nick on replaced network $$net\n";
					}
				}
			}
			for my $chan ($nick->all_chans()) {
				my $hcname = $chan->str($ht);
				unless ($ht->jlink()) {
					my $hchan = $ht->chan($hcname);
					if (!$hchan || $hchan ne $chan) {
						print $dump "nick $$nick on dropped channel $$chan=$hcname\n";
						push @fixes, +{
							type => 'KICK',
							dst => $chan,
							kickee => $nick,
							msg => 'Please rejoin | Fixing internal corruption',
						};
						next;
					}
				}
				my $kn = $chan->keyname();
				my $rf = $Janus::gchans{$kn};
				if (!$rf || $rf ne $chan) {
					print $dump "nick $$nick on miskeyed channel $$chan=$kn\n";
				}
			}
		}
		my %seen;
		for my $chan (values %Janus::gchans) {
			next if $seen{$chan}++;
			if ($Janus::gchans{$chan->keyname()} ne $chan) {
				print $dump "channel $$chan is not registered on its keyname\n";
			}
			for my $net ($chan->nets()) {
				my $rf = $Janus::gnets{$net->gid()};
				if (!$rf || $rf ne $net) {
					print $dump "channel $$chan on dropped network $$net\n";
					push @fixes, +{
						type => 'DELINK',
						net => $net,
						reason => 'Fixes from validate',
					};
				} else {
					$rf = $Janus::nets{$net->name()};
					if (!$rf || $rf ne $net) {
						print $dump "channel $$chan on replaced network $$net\n";
					}
				}
			}
			for my $nick ($chan->all_nicks()) {
				my $gid = $nick->gid();
				my $gn = $Janus::gnicks{$gid};
				if (!$gn || $gn ne $nick) {
					print $dump "channel $$chan contains dropped nick $$nick\n";
					push @fixes, +{
						type => 'KICK',
						dst => $chan,
						kickee => $nick,
						msg => 'Please rejoin | Fixing internal corruption',
					};
				}
			}
		}
		for my $net (values %Janus::nets) {
			for my $nick ($net->all_nicks()) {
				my $gid = $nick->gid();
				my $gn = $Janus::gnicks{$gid};
				if (!$gn || $gn ne $nick) {
					print $dump "net $$net contains dropped nick $$nick\n";
				}
				unless ($nick->is_on($net)) {
					print $dump "net $$net contains nick $$nick which doesn't agree\n";
				}
			}
			for my $chan ($net->all_chans()) {
				my $kn = $chan->keyname();
				my $rf = $Janus::gchans{$kn};
				if (!$rf || $rf ne $chan) {
					print $dump "net $$net contains miskeyed channel $$chan=$kn\n";
				}
				unless ($chan->is_on($net)) {
					print $dump "net $$net contains channel $$chan which doesn't agree\n";
				}
				next if $net->jlink();
				my $name = $chan->str($net);
				my $nch = $net->chan($name);
				if (!$nch || $nch ne $chan) {
					print $dump "net $$net has misnamed channel $$chan=$name\n";
				}
			}
		}
		close $dump;
		&Janus::jmsg($nick, 'Verification report in file log/verify-'.$ts);
		if ($tryfix eq 'yes') {
			&Janus::insert_full(@fixes);
			&Janus::jmsg($nick, 'Fixes applied');
		}
	},
});

1;
