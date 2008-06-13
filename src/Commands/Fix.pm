# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::Fix;
use strict;
use warnings;

# Fixes that should not be needed under normal conditions

sub fix {
	my %chans;
	$chans{$$_} = $_ for values %Janus::gchans;
	for my $chan (values %chans) {
		my %nicks;
		$nicks{$$_} = $_ for @{$Channel::nicks[$$chan]};
		$Channel::nicks[$$chan] = [ values %nicks ];
	}
}

&Janus::command_add({
	cmd => 'fix',
	acl => 1,
	code => \&fix,
});

1;
