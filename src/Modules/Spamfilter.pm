# Copyright (C) 2007-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Modules::Spamfilter;
use strict;
use warnings;

our %exprs;
Janus::save_vars(exprs => \%exprs);

Event::command_add({
	cmd => 'spamfilter',
	help => 'Manages spamfilters (autokill on text)',
	details => [
		"\002SPAMFILTER ADD\002 <perl regex>   Add spamfilter",
		"\002SPAMFILTER DEL\002 <index>...     Remove spamfilter(s)",
		"\002SPAMFILTER LIST\002               Lists active spamfilters",
		"\002SPAMFILTER LISTALL\002            Lists all network's active spamfilters",
		'Spamfilters are applied to all channels your network owns, and privmsgs',
		'or notices to any user connected to your network',
	],
	syntax => 'action <expression>',
	api => '=src =replyto localdefnet $ @',
	acl => 'spamfilter',
	code => sub {
		my($src,$dst,$net,$act,@args) = @_;
		$exprs{$net->name} ||= [];
		my $netlist = $exprs{$net->name};
		$act = lc $act;
		if ($act eq 'list') {
			my @tbl = [ '', 'Expression', 'Setter', 'Set on' ];
			my $c = 0;
			for my $exp (@$netlist) {
				my @row = (++$c, @$exp);
				1 while $row[1] =~ s/^\(\?-xism:(.*)\)$/$1/;
				$row[3] = scalar gmtime $row[3];
				push @tbl, \@row;
			}
			Interface::msgtable($dst, \@tbl) if @tbl > 1;
			Janus::jmsg($dst, 'No spamfilters defined') if @tbl == 1;
		} elsif ($act eq 'listall') {
			my @tbl = [ 'net', 'Expression', 'Setter', 'Set on' ];
			for my $nid (keys %exprs) {
				for my $exp (@{$exprs{$nid}}) {
					my @row = ($nid, @$exp);
					1 while $row[1] =~ s/^\(\?-xism:(.*)\)$/$1/;
					$row[3] = scalar gmtime $row[3];
					push @tbl, \@row;
				}
			}
			Interface::msgtable($dst, \@tbl) if @tbl > 1;
			Janus::jmsg($dst, 'No spamfilters defined') if @tbl == 1;
		} elsif ($act eq 'add') {
			my $expr = join '\s', @args;
			eval {
				push @$netlist, [ qr/$expr/, $src->netnick, $Janus::time ];
				Janus::jmsg($dst, 'Added');
				1;
			} or Janus::jmsg($dst, "Could not compile regex: $@");
		} elsif ($act eq 'del') {
			@args = sort { $b <=> $a } @args;
			for (@args) {
				splice @$netlist, $_ - 1, 1;
			}
			Janus::jmsg($dst, 'Done');
		} else {
			Janus::jmsg($dst, 'Invalid command');
		}
	}
});

Event::hook_add(
	MSG => check => sub {
		my $act = shift;
		my $src = $act->{src};
		my $dst = $act->{dst};
		my $msg = $act->{msg};
		my $net = $dst->homenet;
		return 0 if $src->has_mode('oper');
		my $netlist = $exprs{$net->name} or return 0;
		for my $e (@$netlist) {
			if ($msg =~ /$e->[0]/) {
				if ($dst->isa('Channel')) {
					Event::append({
						type => 'MODE',
						src => $net,
						dst => $dst,
						dirs => [ '+' ],
						mode => [ 'ban' ],
						args => [ $src->vhostmask ],
					});
				}
				Event::append(+{
					type => 'KILL',
					net => $net,
					src => $net,
					dst => $src,
					msg => 'Spamfilter triggered',
				});
				return 1;
			}
		}
		undef;
	},
);

1;
