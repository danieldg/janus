# Copyright (C) 2007-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::List;
use strict;
use warnings;

Event::command_add({
	cmd => 'list',
	help => 'List channels available for linking',
	section => 'Channel',
	api => '=src =replyto',
	code => sub {
		my($src,$dst) = @_;
		my $detail = Account::acl_check($src, 'oper');

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
		Interface::msgtable($dst, \@lines);
	},
}, {
	cmd => 'linked',
	help => 'Shows a list of the linked networks and channels',
	section => 'Info',
	api => '=src =replyto localdefnet',
	syntax => '[<network>]',
	code => sub {
		my($src, $dst, $hnet) = @_;
		my $hnetn = $hnet->name();
		my %chans;
		for my $chan ($hnet->all_chans()) {
			my %nets = map { $$_ => $_ } $chan->nets();
			delete $nets{$$hnet};
			delete $nets{$$Interface::network};
			next unless scalar keys %nets;
			my $cnet = $chan->homenet();
			my $cname = $chan->lstr($cnet);
			my $hname = $chan->lstr($hnet);
			my $hcol;
			my @list = ($hnetn);
			if ($hnet == $cnet) {
				$hcol = "\002$hnetn\002";
				@list = ();
			} elsif ($cname eq $hname) {
				$hcol = "\002".$cnet->name()."\002";
			} else {
				$hcol = "\002".$cnet->name()."$cname\002";
			}
			for my $net (values %nets) {
				next if $net == $hnet || $net == $cnet;
				my $oname = $chan->lstr($net);
				push @list, $net->name().($cname eq $oname ? '' : $oname);
			}
			$chans{$hname} = [ $hname, $hcol, join ' ', sort @list ];
		}
		my @table = map $chans{$_}, sort keys %chans;
		my $netlist = join ' ', grep !($_ eq 'janus' || $_ eq $hnetn), sort keys %Janus::nets;
		unshift @table, [ 'Linked Networks:', "\002$hnetn\002", $netlist ];
		Interface::msgtable($dst, \@table);
	}
});

1;
