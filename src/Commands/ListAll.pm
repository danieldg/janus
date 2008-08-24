# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::ListAll;
use strict;
use warnings;

&Janus::command_add({
	cmd => 'listall',
	help => 'Shows a list of all shared channels visible to this janus server',
	code => sub {
		my($src,$dst) = @_;
		my %seen;
		my @out;
		for my $chan (values %Janus::gchans) {
			next if $seen{$chan}++;
			my @nets = $chan->nets;
			next if @nets == 1;
			my $name = $chan->str($chan->homenet);
			my @netlist;
			for my $net (@nets) {
				my $netn = $net->name;
				$netn = "\002$netn\002" if $net == $chan->homenet;
				next if $net == $Interface::network;
				my $oname = $chan->str($net);
				if (lc $oname ne lc $name) {
					push @netlist, $netn.$oname;
				} else {
					push @netlist, $netn;
				}
			}
			push @out, join ' ', $name, sort @netlist;
		}
		&Janus::jmsg($dst, sort { lc($a) cmp lc($b) } @out);
	}
});

1;
