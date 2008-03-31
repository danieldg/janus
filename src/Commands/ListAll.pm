# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::ListAll;
use strict;
use warnings;

&Janus::command_add({
	cmd => 'listall',
	help => 'Shows a list of all shared channels visible to this janus server',
	acl => 1,
	code => sub {
		my $nick = shift;
		my %seen;
		my @out;
		for my $chan (values %Janus::gchans) {
			next if $seen{$chan}++;
			my @nets = $chan->nets();
			next if @nets == 1;
			my(@namelist, @netlist, $name, $rename);
			for my $net (@nets) {
				my $oname = lc $chan->str($net);
				push @netlist, $net->name();
				push @namelist, $net->name().$oname;
				if ($name && $oname ne $name) {
					$rename++;
				}
				$name = $oname;
			}
			push @out, join ' ', $rename ? ('', @namelist) : ($name, @netlist);
		}
		&Janus::jmsg($nick, sort @out);
	}
});

1;
