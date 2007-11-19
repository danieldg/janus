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
		my $nick = shift;
		return &Janus::jmsg($nick, "You must be an IRC operator to use this command") unless $nick->has_mode('oper');
		my $ts = time;
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
					print $dump "nick $$nick on dropped network $$net\n";
				}
				$rf = $Janus::nets{$net->name()};
				if (!$rf || $rf ne $net) {
					print $dump "nick $$nick on replaced network $$net\n";
				}
			}
			for my $chan ($nick->all_chans()) {
				my $hcname = $chan->str($ht);
				my $hchan = $ht->chan($hcname);
				if (!$hchan || $hchan ne $chan) {
					print $dump "nick $$nick on dropped channel $$chan=$hcname\n";
				}
				my $kn = $chan->keyname();
				my $rf = $Janus::gchans{$kn};
				if (!$rf || $rf ne $chan) {
					print $dump "nick $$nick on miskeyed channel $$chan=$kn\n";
				}
			}
		}
		for my $chan (values %Janus::gchans) {
			for my $net ($chan->nets()) {
				my $rf = $Janus::gnets{$net->gid()};
				if (!$rf || $rf ne $net) {
					print $dump "channel $$chan on dropped network $$net\n";
				}
				$rf = $Janus::nets{$net->name()};
				if (!$rf || $rf ne $net) {
					print $dump "channel $$chan on replaced network $$net\n";
				}
			}
			for my $nick ($chan->all_nicks()) {
				my $gid = $nick->gid();
				my $gn = $Janus::gnicks{$gid};
				if (!$gn || $gn ne $nick) {
					print $dump "channel $$chan contains dropped nick $$nick\n";
				}
			}
		}
		close $dump;
		&Janus::jmsg($nick, 'Verification report in file log/verify-'.$ts);
	},
});

1;
