# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Modules::BanSet;
use Persist;
use strict;
use warnings;

our @sets;
&Janus::save_vars(sets => @sets);

# set => {
#	name   banset name
#	to     single network name
#	item   (nick|ident|host|ip|name)
#	hash   { item => 1 }
# }

sub find {
	my($new, $netto) = @_;
	my $to = $netto->name;
	my $nick = $new->homenick;
	for my $set (@sets) {
		next unless $set->{to} eq $to;
		my $itm = $set->{item} eq 'nick' ? $nick : $nick->info($set->{item});
		next unless defined $itm;
		next unless $set->{hash}{$itm};
		return $set;
	}
	undef;
}

&Janus::command_add({
	cmd => 'banset',
	help => 'Manages Janus ban sets (bans many remote users)',
	details => [
		'Bans are matched on connects to shared channels, and generate autokicks.',
		" \002banset list\002             List all ban sets",
		" \002banset create\002 set type  Creates a new banset",
		" \002banset destroy\002 set      Destroys a banset",
		" \002banset show\002 set         List the contents of a banset",
		" \002banset add\002 set item     Adds an item to a banset",
		" \002banset del\002 set item     Removes an item from a banset",
		'Type is (nick|ident|host|ip|name)',
	],
	acl => 1,
	code => sub {
		my $nick = shift;
		my($cmd, $name, $args) = split /\s+/, shift, 3;
		return &Janus::jmsg($nick, "use 'help banset' to see the syntax") unless $cmd;
		my $net = $nick->homenet;
		$cmd = lc $cmd;
		my %byname = map { $_->{name}, $_ } @sets;
		if ($cmd eq 'list') {
			for my $sname (sort keys %byname) {
				my $set = $byname{$sname};
				my $size = scalar keys %{$set->{hash}};
				&Janus::jmsg($nick, "$sname matches $set->{item} to $set->{to} with $size entries");
			}
			&Janus::jmsg($nick, 'No bansets defined') unless @sets;
		} elsif ($cmd eq 'create' && $args) {
			return &Janus::jmsg($nick, 'Banset already exists') if $byname{$name};
			push @sets, {
				name => $name,
				to => $net->name,
				item => $args,
				hash => {},
			};
			&Janus::jmsg($nick, 'Created');
		} elsif ($cmd eq 'destroy') {
			return &Janus::jmsg($nick, 'Banset not found') unless $byname{$name};
			@sets = grep { $_->{name} ne $name } @sets;
			&Janus::jmsg($nick, 'Deleted');
		} elsif ($cmd eq 'show') {
			return &Janus::jmsg($nick, 'Banset not found') unless $byname{$name};
			my $hash = $byname{$name}{hash};
			&Janus::jmsg($nick, map { ' '.$_ } sort keys %$hash);
		} elsif ($cmd eq 'add') {
			return &Janus::jmsg($nick, 'Banset not found') unless $byname{$name};
			$byname{$name}{hash}{$args} = 1;
		} elsif ($cmd eq 'del') {
			return &Janus::jmsg($nick, 'Banset not found') unless $byname{$name};
			my $itm = delete $byname{$name}{hash}{$args};
			&Janus::jmsg($nick, defined $itm ? 'Deleted' : 'Not found');
		} else {
			&Janus::jmsg($nick, "use 'help banset' to see the syntax");
		}
	}
});
&Janus::hook_add(
	CONNECT => check => sub {
		my $act = shift;
		my $nick = $act->{dst};
		my $net = $act->{net};
		return undef if $net->jlink();
		return undef if $nick->has_mode('oper');

		my $ban = find($nick, $net);
		if ($ban) {
			if ($act->{for}) {
				&Janus::append({
					type => 'MODE',
					src => $net,
					dst => $act->{for},
					dirs => [ '+' ],
					mode => [ 'ban' ],
					args => [ $nick->vhostmask ],
				});
			}
			my $msg = "Banned from ".$net->netname." by list '$ban->{name}'";
			&Janus::append(+{
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
