# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Commands::Dealloc;
use strict;
use warnings;
our($VERSION) = '$Rev$' =~ /(\d+)/;

&Janus::command_add({
	cmd => 'dealloc',
	# no help. You don't want to use this command.
	code => sub {
		my($nick,$args) = @_;
		return &Janus::jmsg($nick, "You must be an IRC operator to use this command") unless $nick->has_mode('oper');
		$args =~ /(\S+) (\S+)/ or return;
		my $pkv = $Persist::vars{$1};
		my $n = $2 + 0 or return;
		for my $ar (values %$pkv) {
			delete $ar->[$n];
		}
	},
});

1;
