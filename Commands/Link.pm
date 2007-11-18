# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Commands::Link;
use strict;
use warnings;
our($VERSION) = '$Rev$' =~ /(\d+)/;

&Janus::command_add({
	cmd => 'req',
	help => 'Manipulate channel link requests',
	details => [
		"\002REQ LIST\002 - list pending channel link requests",
		"\002REQ DEL\002 chan net  - delete a pending request",
	],
	code => sub {
		my($nick,$args) = @_;
		return &Janus::jmsg($nick, "You must be an IRC operator to use this command") unless $nick->has_mode('oper');
		my $hnet = $nick->homenet();
		my $reqs = $hnet->all_reqs();
		if ($args =~ /^l/i) {
			my %reqs = $reqs ? %$reqs : ();
			for my $chan (sort keys %reqs) {
				my $out = ' '.$chan;
				for my $net (sort keys %{$reqs{$chan}}) {
					$out .= ' ' . $net . $reqs{$chan}{$net};
				}
				&Janus::jmsg($nick, $out);
			}
		} elsif ($args =~ /^d\S* (#\S*) (\S+)/i) {
			if ($reqs && delete $reqs->{$1}{$2}) {
				&Janus::jmsg($nick, 'Deleted');
			} else {
				&Janus::jmsg($nick, 'Not found');
			}
		} else {
			&Janus::jmsg($nick, 'Invalid syntax. See "help req" for the proper syntax');
		}
	}
});

1;
