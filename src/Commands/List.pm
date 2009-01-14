# Copyright (C) 2007-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::List;
use strict;
use warnings;

&Event::command_add({
	cmd => 'list',
	help => 'List channels available for linking',
	section => 'Channel',
	api => '=src =replyto',
	code => sub {
		my($src,$dst) = @_;
		my $detail = &Account::acl_check($src, 'oper');

		my @lines;

		for my $net (sort keys %Janus::nets) {
			my $avail = $Link::request{$net} or next;

			for my $chan (keys %$avail) {
				next unless $avail->{$chan}{mode};
				my @line = ($chan, $net);
				push @line, $avail->{$chan}{mask},
					scalar gmtime($avail->{$chan}{time}) if $detail;
				push @lines, \@line;
			}
		}
		@lines = sort { $a->[0] cmp $b->[0] } @lines;
		unshift @lines, [ 'Channel', 'Net', ($detail ? ('Created by', 'Created on') : ()) ];
		&Interface::msgtable($dst, \@lines);
	},
});

1;
