# Copyright (C) 2007-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Modules::BanSet;
use Persist;
use strict;
use warnings;

our @sets;
&Janus::save_vars(sets => \@sets);

# set => {
#	name   banset name
#	to     comma-separated network names
#	item   (nick|ident|host|ip|name)
#	hash   { item => 1 }
# }

sub find {
	my($new, $netto) = @_;
	my $to = $netto->name;
	for my $set (@sets) {
		next unless grep $_ eq $to, split ',', $set->{to};
		my $itm = $set->{item} eq 'nick' ? $new->homenick : $new->info($set->{item});
		next unless defined $itm;
		next unless $set->{hash}{$itm};
		return $set;
	}
	undef;
}

&Event::command_add({
	cmd => 'banset',
	help => 'Manages Janus ban sets (bans many remote users)',
	section => 'Network',
	details => [
		'Bans are matched on connects to shared channels, and generate autokicks.',
		" \002banset list\002             List all ban sets",
		" \002banset create\002 set type  Creates a new banset",
		" \002banset destroy\002 set      Deletes a banset (from all networks)",
		" \002banset addnet\002 set       Adds your network to the banset",
		" \002banset delnet\002 set       Removes your network from the banset",
		" \002banset show\002 set         List the contents of a banset",
		" \002banset add\002 set item     Adds an item to a banset",
		" \002banset del\002 set item     Removes an item from a banset",
		'Type is (nick|ident|host|ip|name)',
	],
	acl => 'ban',
	code => sub {
		my($src, $dst, $cmd, $name, @args) = @_;
		return &Janus::jmsg($dst, "use 'help banset' to see the syntax") unless $cmd;
		my $net = $src->homenet;
		$cmd = lc $cmd;
		my %byname = map { $_->{name}, $_ } @sets;
		if ($cmd eq 'list') {
			for my $sname (sort keys %byname) {
				my $set = $byname{$sname};
				my $size = scalar keys %{$set->{hash}};
				&Janus::jmsg($dst, "$sname matches $set->{item} to $set->{to} with $size entries");
			}
			&Janus::jmsg($dst, 'No bansets defined') unless @sets;
		} elsif ($cmd eq 'create' && @args) {
			return &Janus::jmsg($dst, 'Banset already exists') if $byname{$name};
			push @sets, {
				name => $name,
				to => $net->name,
				item => $args[0],
				hash => {},
			};
			&Janus::jmsg($dst, 'Created');
		} elsif ($cmd eq 'destroy') {
			return &Janus::jmsg($dst, 'Banset not found') unless $byname{$name};
			my $set = $byname{$name};
			@sets = grep { $_->{name} ne $name } @sets;
			&Janus::jmsg($dst, 'Banset destroyed');
		} elsif ($cmd eq 'addnet') {
			return &Janus::jmsg($dst, 'Banset not found') unless $byname{$name};
			my $set = $byname{$name};
			my $netn = $net->name;
			return &Janus::jmsg($dst, 'Already in banset') if grep $_ eq $netn, split ',', $set->{to};
			$set->{to} .= ','.$netn;
			&Janus::jmsg($dst, 'Added');
		} elsif ($cmd eq 'delnet') {
			return &Janus::jmsg($dst, 'Banset not found') unless $byname{$name};
			my $set = $byname{$name};
			my %to; $to{$_}++ for split ',', $set->{to};
			return &Janus::jmsg($dst, 'Not in banset') unless delete $to{$net->name};
			$set->{to} = join ',', keys %to;
			&Janus::jmsg($dst, 'Removed');
		} elsif ($cmd eq 'show') {
			return &Janus::jmsg($dst, 'Banset not found') unless $byname{$name};
			my $hash = $byname{$name}{hash};
			&Janus::jmsg($dst, map { ' '.$_ } sort keys %$hash);
		} elsif ($cmd eq 'add' && @args) {
			return &Janus::jmsg($dst, 'Banset not found') unless $byname{$name};
			$byname{$name}{hash}{$args[0]} = 1;
		} elsif ($cmd eq 'del' && @args) {
			return &Janus::jmsg($dst, 'Banset not found') unless $byname{$name};
			my $itm = delete $byname{$name}{hash}{$args[0]};
			&Janus::jmsg($dst, defined $itm ? 'Deleted' : 'Not found');
		} else {
			&Janus::jmsg($dst, "use 'help banset' to see the syntax");
		}
	}
});
&Event::hook_add(
	CONNECT => check => sub {
		my $act = shift;
		my $nick = $act->{dst};
		my $net = $act->{net};
		return undef if $net->jlink || $net == $Interface::network;
		return undef if $nick->has_mode('oper');

		my $ban = find($nick, $net);
		if ($ban) {
			if ($act->{for}) {
				&Event::append({
					type => 'MODE',
					src => $net,
					dst => $act->{for},
					dirs => [ '+' ],
					mode => [ 'ban' ],
					args => [ $nick->vhostmask ],
				});
			}
			my $msg = "Banned from ".$net->netname." by list '$ban->{name}'";
			&Event::append(+{
				type => 'KILL',
				dst => $nick,
				net => $net,
				msg => $msg,
			});
			return 1;
		}
		undef;
	},
);

1;
