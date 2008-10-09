# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::List;
use strict;
use warnings;

&Janus::command_add({
	cmd => 'list',
	help => 'List channels available for linking',
	section => 'Channel',
	code => sub {
		my($src,$dst) = @_;
		my $detail = &Account::acl_check($src, 'oper');

		my @lines;

		for my $net (sort keys %Janus::nets) {
			my $avail = $Link::request{$net} or next;

			for my $chan (keys %$avail) {
				next unless $avail->{$chan}{mode};
				my @line = ($chan, $net);
				push @line, $avail->{$chan}{mask}.' '.gmtime($avail->{$chan}{time}) if $detail;
				push @lines, \@line;
			}
		}
		@lines = sort { $a->[0] cmp $b->[0] } @lines;
		unshift @lines, [ 'Channel', 'net', ($detail ? ('Created by') : ()) ];
		&Interface::msgtable($dst, \@lines, 1);
	},
});

1;
