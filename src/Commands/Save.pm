# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::Save;
use strict;
use warnings;
use Data::Dumper;

sub save {
	my $out = $Conffile::netconf{set}{save};
	my(@vars,@refs);
	keys %Janus::states;
	while (my($class,$vars) = each %Janus::states) {
		keys %$vars;
		while (my($var,$val) = each %$vars) {
			push @vars, $val;
			push @refs, '*'.$class.'::'.$var;
		}
	}
	open my $f, '>', $out or return 0;
	print $f Data::Dumper->Dump(\@vars, \@refs);
	close $f;
	return 1;
}

&Janus::command_add({
	cmd => 'save',
	help => 'Save janus state to filesystem',
	acl => 1,
	code => sub {
		my($nick,$args) = @_;
		if (save()) {
			&Janus::jmsg($nick, 'Saved');
		} else {
			&Janus::jmsg($nick, "Could not save: $!");
		}
	}
});

1;
