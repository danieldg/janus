# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Link;
use strict;
use warnings;
use integer;
use Debug;
use Persist;
use Scalar::Util qw(weaken);
our %reqs;
# {requestor}{destination}{src-channel} = {
#  src => src-channel [? if ever useful]
#  dst => dst-channel
#  mask => nick!ident@host of requestor
#  time => unix timestamp of request

our %bylock;
# lockid => Link

our $lockmax;

# Emergency shutoff switch for retries
our $abort;

our(@lock, @chan, @ready, @expire, @other, @origin);
&Persist::register_vars(lockid => \@lock, qw(chan ready expire other origin));
&Persist::autoget(lockid => \@lock);
&Persist::autoinit(qw(other origin));

sub _init {
	my $link = shift;
	my $id = $RemoteJanus::self->id().':'.++$lockmax;
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
}

sub ready {
	my $link = shift;
	my $chan = $chan[$$link] or return 0;
	for my $net ($chan->nets()) {
		my $jl = $net->jlink() || $RemoteJanus::self;
		return 0 unless $ready[$$link]{$jl};
	}
	1;
}

sub unlock {
	my $link = shift;
	delete $bylock{$lock[$$link]};
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
			while (my($src,$ifo) = each %$bychan) {
				$ifo = { dst => $ifo } unless ref $ifo;
				push @acts, +{
					type => 'LINKREQ',
					net => $net,
					dst => $dnet,
					slink => $src,
					dlink => $ifo->{dst},
					reqby => $ifo->{nick},
					reqtime => $ifo->{time},
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
				next if $ij->jparent($net->jlink());
				my $bychan = $reqs{$net->name()}{$lto->name()};
				keys %$bychan;
				while (my($src,$ifo) = each %$bychan) {
					$ifo = { dst => $ifo } unless ref $ifo;
					push @acts, +{
						type => 'LINKREQ',
						net => $net,
						dst => $lto,
						slink => $src,
						dlink => $ifo->{dst},
						reqby => $ifo->{nick},
						reqtime => $ifo->{time},
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
		# don't let people request reflexive links
		return if $snet eq $dnet;
		$reqs{$snet->name()}{$dnet->name()}{lc $act->{slink}} = {
			dst => $act->{dlink},
			nick => $act->{reqby},
			'time' => $act->{reqtime},
		};
		if ($dnet->jlink() || $dnet->isa('Interface')) {
			&Debug::info("Link request: dst non-local");
			return;
		}
		unless ($dnet->is_synced()) {
			&Debug::info("Link request: dst not ready");
			return;
		}
		my $recip = $reqs{$dnet->name()}{$snet->name()}{lc $act->{dlink}};
		$recip = $recip->{dst} if ref $recip;
		unless ($recip) {
			&Debug::info("Link request: saved in list");
			return;
		}
		if ($act->{linkfile} && $act->{linkfile} == 2) {
			&Debug::info("Link request: not syncing to avoid races");
			return;
		}
		my $kn1 = $snet->gid().$act->{slink};
		my $kn2 = $dnet->gid().$act->{dlink};
		if ($Janus::gchans{$kn1} && $Janus::gchans{$kn2} &&
			$Janus::gchans{$kn1} eq $Janus::gchans{$kn2}) {
			&Debug::info("Link request: already linked");
			return;
		}
		if ($act->{override} || $recip eq 'any' || lc $recip eq lc $act->{slink}) {
			&Debug::info("Link request: linking!");
			my $link1 = Link->new(origin => $act);
			my $link2 = Link->new(origin => $act, other => $link1);
			$other[$$link1] = $link2;
			weaken($other[$$link1]);
			weaken($other[$$link2]);
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
		} else {
			&Debug::info("Link request: name mismatch");
		}
	}, LOCKACK => act => sub {
		my $act = shift;
		my $link = $bylock{$act->{lockid}};
		unless ($link) {
			# is it our lock?
			$act->{lockid} =~ /(.+):\d+/;
			return unless $1 eq $RemoteJanus::self->id();
			# unlock. We didn't actually need it.
			&Janus::append({
				type => 'UNLOCK',
				dst => $act->{chan},
				lockid => $act->{lockid},
			});
			return;
		}
		my $exp = $act->{expire} || 0;
		my $other = $other[$$link];
		if ($exp < $expire[$$link]) {
			$expire[$$link] = $exp;
		} else {
			$exp = $expire[$$link];
		}
		$exp = $expire[$$other] if $expire[$$other] < $exp;
		if ($exp < $Janus::time) {
			&Debug::info("Lock ".$link->lockid()." & ".$other->lockid()." failed");
			$link->unlock();
			$other->unlock();
			$other[$$link] = $other[$$other] = undef;

			# Retry linking a few times; this is needed because channel locking
			# will prevent links when syncing more than one network to a channel
			# which has an inter-janus member.

			my $relink = $origin[$$link];
			$relink->{linkfile}++;
			$relink->{linkfile} = 3 if $relink->{linkfile} < 3;
			# linkfile, if 3 or greater, is the retry count
			&Janus::schedule(+{
				# randomize the delay to try to avoid collisions
				delay => (10 + int(rand(10))),
				code => sub {
					&Janus::append($relink);
				}
			}) unless $relink->{linkfile} > 20 || $abort;
			return;
		}
		$chan[$$link] ||= $act->{chan};
		$ready[$$link]{$act->{src}}++;
		return unless $link->ready() && $other->ready();
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

		my $sname = $snet->name();
		my $scname = lc($chan->str($snet) || $act->{split}->str($snet));
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
