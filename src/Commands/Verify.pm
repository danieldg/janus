# Copyright (C) 2007-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::Verify;
use strict;
use warnings;
use Scalar::Util 'blessed';

my (@err, %cseen, %nseen, %sseen, %n_c);

sub v_chan;
sub v_nick;
sub v_serv;

sub v_nick {
	my($nick,$path,$top) = @_;
	if (ref $nick eq 'Persist::Poison') {
		my $id = $$nick->{id};
		push @err, "Poisoned nick $id ($Nick::gid[$id] = $Nick::homenick[$id]) in $path";
		return;
	}
	unless ($nick->isa('Nick')) {
		push @err, "non-nick nick $$nick (".ref($nick).") found in $path";
		return;
	}

	return if $nseen{$$nick} && !$top;
	$nseen{$$nick} = $nick;

	my $gid = $nick->gid;
	my $hn = $nick->homenick;
	my $hs = $nick->homenet;

	if ($Janus::gnicks{$gid} == $nick) {
		return unless $top;
	} else {
		push @err, "nick $$nick not in gnicks at $gid; found in $path";
	}
	if ($hs) {
		v_serv $hs, "nick $$nick (homenet) <= $path";
	} else {
		push @err, "nick $$nick with no homenet found in $path";
	}

	for my $net ($nick->netlist) {
		v_serv $net, "nick $$nick (netlist) <= $path";
		if ($net->isa('LocalNetwork')) {
			my $name = $nick->str($net);
			my $byname = $net->nick($name, 1);
			if ($byname != $nick) {
				push @err, "nick $$nick not associated with '$name' in net $$net; found in $path";
			}
		}
	}
	for my $chan ($nick->all_chans) {
		v_chan $chan, "nick $$nick (chanlist) <= $path";
		$n_c{$$nick.'-'.$$chan} |= 1;
	}
}

sub v_serv {
	my($net, $path, $top) = @_;
	if (ref $net eq 'Persist::Poison') {
		my $id = $$net->{id};
		push @err, "Poisoned network $id ($Network::gid[$id] = $Network::name[$id]) in $path";
		return;
	}
	unless ($net->isa('Network')) {
		push @err, "non-network net $$net (".ref($net).") found in $path";
		return;
	}

	return if $sseen{$$net} && !$top;
	$sseen{$$net} = $net;

	my $gid = $net->gid;
	my $name = $net->name;

	if ($Janus::gnets{$gid} == $net) {
		return unless $top;
	} else {
		push @err, "net $$net ($name - $gid) not in gnets; found in $path";
	}
	if ($Janus::nets{$name} != $net) {
		push @err, "net $$net ($name - $gid) not in nets; found in $path";
	}

	for my $nick ($net->all_nicks) {
		v_nick $nick, "network $$net (nicklist) <= $path";
	}

	for my $chan ($net->all_chans) {
		v_chan $chan, "network $$net (chanlist) <= $path";
	}
}

sub v_chan {
	my($chan, $path) = @_;
	if (ref $chan eq 'Persist::Poison') {
		my $id = $$chan->{id};
		push @err, "Poisoned channel $id ($Channel::keyname[$id]) in $path";
		return;
	}
	unless (blessed $chan && $chan->isa('Channel')) {
		push @err, "non-channel chan (".ref($chan).") found in $path";
		return;
	}

	return if $cseen{$$chan};
	$cseen{$$chan} = $chan;

	my $kn = $chan->keyname;
	my $hnet = $chan->homenet;

	if ($kn && $Janus::gchans{$kn} != $chan) {
		push @err, "channel $$chan not in gchans at $kn; found in $path";
	}
	if (!$kn && $Janus::gchans{$chan->real_keyname}) {
		my $imp = $Janus::gchans{$chan->real_keyname};
		if ($imp == $chan) {
			push @err, "Channel $$chan in gchans but is not keyed";
		} else {
			push @err, "Channel $$imp in gchans with keyname from $$chan (from $path)";
		}
	}

	for my $net ($chan->nets) {
		v_serv $net, "channel $$chan (netlist) <= $path";
		my $name = $chan->str($net);
		if ($net->isa('LocalNetwork') && $net->chan($name) != $chan) {
			push @err, "channel $$chan not associated with $name in network $$net; found in $path";
		}
	}

	for my $nick ($chan->all_nicks) {
		v_nick $nick, "channel $$chan (nicklist) <= $path";
		$n_c{$$nick.'-'.$$chan} |= 2;
	}
}

sub verify {
	my($src, $dst) = @_;
	my $ts = $Janus::time;
	(@err, %cseen, %nseen, %sseen, %n_c) = ();

	v_nick $_,'gnicks',1 for values %Janus::gnicks;
	v_serv $_,'gnets',1 for values %Janus::gnets;
	v_serv $_,'nets' for values %Janus::nets;
	v_chan $_,'gchans' for values %Janus::gchans;

	while (my($k,$v) = each %n_c) {
		next if $v == 3;
		if ($v == 1) {
			push @err, "membership n-c $k is in nick's table but not channel's";
		} elsif ($v == 2) {
			push @err, "membership n-c $k is in channel's table but not nick's";
		}
	}

	if (@err) {
		open my $dump, '>', "log/verify-$ts" or return;
		print $dump "$_\n" for @err;
		close $dump;
		my $c = scalar @err;
		my $max = $c > 10 ? 10 : ($c - 1);
		Janus::jmsg($dst, @err[0..$max]);
		Janus::jmsg($dst, "$c problems found - full report is in log/verify-$ts");
	} else {
		Janus::jmsg($dst, 'No problems found');
	}
	(@err, %cseen, %nseen, %sseen, %n_c) = ();
}

Event::command_add({
	cmd => 'verify',
	acl => 'verify',
	help => 'Verifies janus internal state',
	section => 'Admin',
	code => \&verify,
});

1;
