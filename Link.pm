# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Link;
use strict;
use warnings;
use Persist;

our($VERSION) = '$Rev$' =~ /(\d+)/;

our %reqs;
# {requestor}{destination}{src-channel} = dst-channel

our %bylock;
# lockid => Link

our $lockmax;
my @lock   :Persist(lockid) :Get(lockid);
my @chan   :Persist(chan);
my @ready  :Persist(ready);
my @expire :Persist(expire);
my @other  :Persist(other)  :Arg(other);

sub _init {
	my $link = shift;
	my $id = $Janus::name.':'.++$lockmax;
	$lock[$$link] = $id;
	$expire[$$link] = $Janus::time + 61;
	$bylock{$id} = $link;
	&Janus::schedule(+{
		delay => 61,
		code => sub {
			my $l = delete $bylock{$id};
			$other[$$l] = undef if $l;
		}
	});
	print "Link $$link alloc'd\n";
}

sub _destroy {
	print "Link ${$_[0]} dealloc'd\n";
}

sub ready {
	my $link = shift;
	my $chan = $chan[$$link] or return 0;
	for my $net ($chan->nets()) {
		my $jl = $net->jlink() || $Janus::server;
		return 0 unless $ready[$$link]{$jl};
	}
	1;
}

sub unlock {
	my $link = shift;
	return unless $chan[$$link];
	&Janus::append({
		type => 'UNLOCK',
		dst => $chan[$$link],
		lockid => $lock[$$link],
	});
}

&Janus::save_vars('reqs', \%reqs);

&Janus::hook_add(
	NETLINK => act => sub {
		my $act = shift;
		my $net = $act->{net};
		return unless $net->jlink();
		# clear the request list as it will be repopulated as part of the remote sync
		delete $reqs{$net->name()};
	}, LINKED => act => sub {
		my $act = shift;
		my $net = $act->{net};
		return if $net->jlink();
		my $bynet = $reqs{$net->name()} or return;
		keys %$bynet; # reset iterator
		my @acts;
		while (my($nname,$bychan) = each %$bynet) {
			next unless $bychan;
			my $dnet = $Janus::nets{$nname} or next;
			keys %$bychan;
			while (my($src,$dst) = each %$bychan) {
				push @acts, +{
					type => 'LINKREQ',
					net => $net,
					dst => $dnet,
					slink => $src,
					dlink => $dst,
					linkfile => 1,
				};
			}
		}
		&Janus::append(@acts);
	}, JLINKED => act => sub {
		my $act = shift;
		my $ij = $act->{except};
		my @nets = grep { $_->jlink() && $_->jlink() eq $ij } values %Janus::nets;
		my @acts;
		for my $lto (@nets) {
			for my $net (values %Janus::nets) {
				next if $net->jlink();
				my $bychan = $reqs{$net->name()}{$lto->name()};
				keys %$bychan;
				while (my($src,$dst) = each %$bychan) {
					push @acts, +{
						type => 'LINKREQ',
						net => $net,
						dst => $lto,
						slink => $src,
						dlink => $dst,
						linkfile => $ij->is_linked(),
					};
				}
			}
		}
		&Janus::append(@acts);
	}, LINKREQ => act => sub {
		my $act = shift;
		my $snet = $act->{net};
		my $dnet = $act->{dst};
		print "Link request: ";
		$reqs{$snet->name()}{$dnet->name()}{lc $act->{slink}} = $act->{dlink};
		if ($dnet->jlink() || $dnet->isa('Interface')) {
			print "dst non-local\n";
			return;
		}
		unless ($dnet->is_synced()) {
			print "dst not ready\n";
			return;
		}
		my $recip = $reqs{$dnet->name()}{$snet->name()}{lc $act->{dlink}};
		unless ($recip) {
			print "saved in list\n";
			return;
		}
		if ($act->{linkfile} && $act->{linkfile} == 2) {
			print "not syncing to avoid races\n";
			return;
		}
		if ($act->{override} || $recip eq 'any' || lc $recip eq lc $act->{slink}) {
			print "linking!\n";
			my $link1 = Link->new();
			my $link2 = Link->new(other => $link1);
			$other[$$link1] = $link2;
			&Janus::append(+{
				type => 'LOCKREQ',
				src => $dnet,
				dst => $snet,
				name => $act->{slink},
				lockid => $link1->lockid(),
			}, {
				type => 'LOCKREQ',
				src => $dnet,
				dst => $dnet,
				name => $act->{dlink},
				lockid => $link2->lockid(),
			});
		}
	}, LOCKACK => act => sub {
		my $act = shift;
		my $link = $bylock{$act->{lockid}};
		return unless $link;
		my $exp = $act->{expire};
		if (!$exp) {
			# failed to lock. TODO try again later
			$link->unlock();
			$other[$$link]->unlock();
			return;
		}
		if ($exp < $expire[$$link]) {
			$expire[$$link] = $exp;
		}
		$chan[$$link] ||= $act->{chan};
		$ready[$$link]{$act->{src}}++;
		return unless $link->ready();
		my $other = $other[$$link];
		return unless $other->ready();
		&Janus::append({
			type => 'LOCKED',
			chan1 => $chan[$$link],
			chan2 => $chan[$$other],
		});
		delete $bylock{$link->lockid()};
		delete $bylock{$other->lockid()};
		$other[$$link] = $other[$$other] = undef;
	}, DELINK => act => sub {
		my $act = shift;
		my $src = $act->{src};
		my $chan = $act->{dst};
		return unless $src && $src->isa('Nick');
		my $snet = $src->homenet();
		return if $snet->jlink();

		my $sname = $snet->name();
		my $scname = $chan->str($snet) || $act->{split}->str($snet);
		if ($snet eq $act->{net}) {
			# delink own network: delete all outgoing requests
			for my $net ($chan->nets()) {
				next if $net eq $snet;
				delete $reqs{$sname}{$net->name()}{$scname};
			}
		} else {
			# delink other network: delete only that request
			delete $reqs{$sname}{$act->{net}->name()}{$scname};
		}
	}, REQDEL => act => sub {
		my $act = shift;
		my $src = $act->{snet};
		my $dst = $act->{dnet};
		if (delete $reqs{$src->name()}{$dst->name()}{lc $act->{name}}) {
			&Janus::jmsg($act->{src}, 'Deleted');
		} else {
			&Janus::jmsg($act->{src}, 'Not found');
		}
	},
);

1;
