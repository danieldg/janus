# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Lock;
use strict;
use warnings;
use integer;
use Debug;
use Persist;
use Scalar::Util qw(weaken);

our %bylock;
# lockid => Link

our $lockmax;

our(@lock, @chan, @ready, @expire, @other, @origin);
&Persist::register_vars(lockid => \@lock, qw(chan ready expire other origin));
&Persist::autoget(lockid => \@lock);
&Persist::autoinit(qw(other origin));

our(@locker, @lockts);
&Persist::register_vars('Channel::locker' => \@locker, 'Channel::lockts' => \@lockts);

sub can_lock {
	my $chan = shift;
	return 1 unless $locker[$$chan];
	if ($lockts[$$chan] < $Janus::time) {
		&Debug::info("Stealing expired lock from $locker[$$chan]");
		return 1;
	} else {
		&Debug::info("Lock on #$$chan held by $locker[$$chan] until $lockts[$$chan]");
		return 0;
	}
}

sub _rm_lock {
	my $itm = shift;
	my $l = delete $bylock{$itm->{id}};
	$other[$$l] = undef if $l;
}

sub _retry {
	my $itm = shift;
	&Janus::append($itm->{origin});
}

sub _init {
	my $link = shift;
	my $id = $RemoteJanus::self->id().':'.++$lockmax;
	$lock[$$link] = $id;
	$expire[$$link] = $Janus::time + 61;
	$bylock{$id} = $link;
	&Janus::schedule(+{
		delay => 61,
		id => $id,
		code => \&_rm_lock,
	});
}

sub ready {
	my $link = shift;
	my $chan = $Janus::gchans{$chan[$$link] || ''} or return 0;
	for my $net ($chan->nets()) {
		my $jl = $net->jlink() || $RemoteJanus::self;
		return 0 unless $ready[$$link]{$jl};
	}
	1;
}

sub unlock {
	my $itm = shift;
	if ($itm->isa('Channel')) {
		delete $locker[$$itm];
	} elsif ($itm->isa(__PACKAGE__)) {
		delete $bylock{$lock[$$itm]};
		my $chan = $Janus::gchans{$chan[$$itm]} or return;
		&Janus::append({
			type => 'UNLOCK',
			dst => $chan,
			lockid => $lock[$$itm],
		});
	}
}

sub req_pair {
	my($act,$snet,$dnet) = @_;
	my $link1 = Lock->new(origin => $act);
	my $link2 = Lock->new(origin => $act, other => $link1);
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
}

&Janus::hook_add(
	LOCKREQ => check => sub {
		my $act = shift;
		my $net = $act->{dst};
		if ($net->isa('LocalNetwork')) {
			my $chan = $net->chan($act->{name}, 1) or return 1;
			$act->{dst} = $chan;
		} elsif ($net->isa('Network')) {
			my $kn = $net->gid().lc $act->{name};
			my $chan = $Janus::gchans{$kn};
			$act->{dst} = $chan if $chan;
		}
		return undef;
	}, LOCKREQ => act => sub {
		my $act = shift;
		my $chan = $act->{dst};
		return unless $chan->isa('Channel');

		if (can_lock($chan)) {
			$locker[$$chan] = $act->{lockid};
			$lockts[$$chan] = $Janus::time + 60;
			&Janus::append(+{
				type => 'LOCKACK',
				src => $RemoteJanus::self,
				dst => $act->{src},
				lockid => $act->{lockid},
				chan => $chan,
				expire => ($Janus::time + 40),
			});
		} else {
			&Janus::append(+{
				type => 'LOCKACK',
				src => $RemoteJanus::self,
				dst => $act->{src},
				lockid => $act->{lockid},
			});
		}
	}, UNLOCK => act => sub {
		my $act = shift;
		my $chan = $act->{dst};
		delete $locker[$$chan];
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
				delay => (5 + int(rand(25))),
				origin => $relink,
				code => \&_retry,
			}) unless $relink->{linkfile} > 20 || $Link::abort;
			return;
		}
		$chan[$$link] ||= $act->{chan}->keyname();
		$ready[$$link]{$act->{src}}++;
		return unless $link->ready() && $other->ready();
		&Janus::append({
			type => 'LOCKED',
			chan1 => $Janus::gchans{$chan[$$link]},
			chan2 => $Janus::gchans{$chan[$$other]},
		});
		delete $bylock{$link->lockid()};
		delete $bylock{$other->lockid()};
		$other[$$link] = $other[$$other] = undef;
	},
);

1;
