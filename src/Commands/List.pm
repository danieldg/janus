# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::List;
use strict;
use warnings;

&Janus::command_add({
	cmd => 'list',
	help => 'List channels available for linking',
	details => [
		"Syntax: \002LIST\002 network",
	],
	code => sub {
		my($nick,$args) = @_;

		unless ($args && $args =~ /^\S+$/ && $Janus::nets{$args}) {
			&Janus::jmsg($nick, "Syntax: \002LIST\002 network");
			return;
		}

		my $avail = $Link::avail{$args} || {};
		my @out;
		for my $chan (keys %$avail) {
			# TODO filter out rejected channels
			if ($nick->has_mode('oper')) {
				push @out, $chan.' '.$avail->{$chan}{mask}.' '.gmtime($avail->{$chan}{time});
			} else {
				push @out, $chan;
			}
		}
		if (@out) {
			&Janus::jmsg($nick, @out);
		} else {
			&Janus::jmsg($nick, 'No shared channels for that network');
		}
	},	
});

1;
