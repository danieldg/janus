package Nick; {
use Object::InsideOut ':hash_only';
use strict;
use warnings;
use Scalar::Util 'weaken';

my %homenet :Field :Get(homenet);
my %homenick :Field :Get(homenick);
my %nets :Field;
my %nicks :Field;
my %chans :Field;
my %mode :Field;
my %info :Field;
my %ts :Field :Get(ts);

my %initargs :InitArgs = (
	net => '',
	nick => '',
	ts => '',
	info => '',
	mode => '',
);

sub _init :Init {
	my($nick, $ifo) = @_;
	my $net = $ifo->{net};
	$homenet{$$nick} = $net;
	$homenick{$$nick} = $ifo->{nick};
	my $homeid = $net->id();
	$nets{$$nick} = { $homeid => $net };
	$nicks{$$nick} = { $homeid => $ifo->{nick} };
	$ts{$$nick} = $ifo->{ts} || time;
	$info{$$nick} = $ifo->{info} || {};
	$mode{$$nick} = $ifo->{mode} || {};
}

sub to_ij {
	my($nick, $ij) = @_;
	local $_;
	my $out = '';
# perl -e "print q[\$out .= ' ],\$_,q[='.\$ij->ijstr(\$],\$_,q[{\$\$nick});],qq(\n) for qw/homenet homenick ts nicks mode info/"
	$out .= ' homenet='.$ij->ijstr($homenet{$$nick});
	$out .= ' homenick='.$ij->ijstr($homenick{$$nick});
	$out .= ' ts='.$ij->ijstr($ts{$$nick});
	$out .= ' nicks='.$ij->ijstr($nicks{$$nick});
	$out .= ' mode='.$ij->ijstr($mode{$$nick});
	$out .= ' info=';
	my %sinfo;
	$sinfo{$_} = $info{$$nick}{$_} for 
		qw/host ident ip name vhost/;
	$out . $ij->ijstr(\%sinfo);
}

#sub DESTROY {
#	print "DBG: $_[0] $_[0]->{homenick}\@$_[0]->{homenet}->{id} deallocated\n";
#}

# send to all but possibly one network for NICKINFO
# send to home network for MSG
sub sendto {
	my($nick, $act, $except) = @_;
	if ($act->{type} eq 'MSG') {
		return $homenet{$$nick};
	} elsif ($act->{type} eq 'CONNECT') {
		return $act->{net};
	} else {
		my %n = %{$nets{$$nick}};
		delete $n{$except->id()} if $except;
		return values %n;
	}
}

sub is_on {
	my($nick, $net) = @_;
	return exists $nets{$$nick}{$net->id()};
}

sub has_mode {
	my $nick = $_[0];
	return $mode{$$nick}->{$_[1]};
}

sub umodes {
	my $nick = $_[0];
	return sort keys %{$mode{$$nick}};
}

sub jlink {
	return $homenet{${$_[0]}}->jlink();
}

# vhost, ident, etc
sub info {
	my $nick = $_[0];
	$info{$$nick}{$_[1]};
}

sub rejoin {
	my($nick,$chan) = @_;
	my $name = $chan->str($homenet{$$nick});
	$chans{$$nick}{lc $name} = $chan;

	return if $nick->jlink();
		
	for my $net ($chan->nets()) {
		next if $nets{$$nick}->{$net->id()};
		Janus::insert(+{
			type => 'CONNECT',
			dst => $nick,
			net => $net,
			nojlink => 1,
		});
	}
}

sub _part {
	my($nick,$chan) = @_;
	my $name = $chan->str($homenet{$$nick});
	delete $chans{$$nick}->{lc $name};
	return if $nick->jlink();
	$nick->_netclean($chan->nets());
}

sub _netpart {
	my($nick, $net) = @_;	
	my $id = $net->id();

	delete $nets{$$nick}->{$id};
	return if $net->jlink();
	my $rnick = delete $nicks{$$nick}{$id};
	$net->release_nick($rnick);
}

sub _netclean {
	my $nick = shift;
	return if $info{$$nick}{_is_janus};
	my %leave = @_ ? map { $_->id() => $_ } @_ : %{$nets{$$nick}};
	delete $leave{$homenet{$$nick}->id()};
	for my $chan (values %{$chans{$$nick}}) {
		for my $net ($chan->nets()) {
			delete $leave{$net->id()};
		}
	}
	for my $net (values %leave) {
		# This sending mechanism deliberately bypasses
		# the message queue because a QUIT is intended
		# to destroy the nick from all nets, not just one
		$net->send({
			type => 'QUIT',
			src => $nick,
			dst => $nick,
			msg => 'Left all shared channels',
		}) unless $net->jlink();
		$nick->_netpart($net);
	}
}

sub id {
	my $nick = $_[0];
	return $homenet{$$nick}->id() . '~' . $homenick{$$nick};
}

sub str {
	my($nick,$net) = @_;
	$nicks{$$nick}{$net->id()};
}

sub modload {
 my $me = shift;
 Janus::hook_add($me, 
 	CONNECT => check => sub {
		my $act = shift;
		my $nick = $act->{dst};
		my $net = $act->{net};
		return undef if $net->jlink() || $act->{reconnect};

		my $mask = $homenick{$$nick}.'!'.$info{$$nick}{ident}.'@'.$info{$$nick}{host}.'%'.$homenet{$$nick}->id();
		for my $expr ($net->banlist()) {
			next unless $mask =~ /^$expr$/i;
			my $ban = $net->get_ban($expr);
			Janus::append(+{
				type => 'KILL',
				dst => $nick,
				net => $net,
				msg => "Banned by ".$net->netname().": $ban->{reason}",
			});
			return 1;
		}
		undef;
	}, CONNECT => act => sub {
		my $act = shift;
		my $nick = $act->{dst};
		my $net = $act->{net};
		my $id = $net->id();
		if (exists $nets{$$nick}{$id}) {
			warn "Nick alredy exists";
		}
		$nets{$$nick}->{$id} = $net;
		return if $net->jlink();
		my $rnick = $net->request_nick($nick, $homenick{$$nick}, $act->{reconnect});
		$nicks{$$nick}->{$id} = $rnick;
		if ($act->{reconnect}) {
			delete $act->{except};
			$act->{reconnect_chans} = [ values %{$chans{$$nick}} ];
		}
	}, NICK => check => sub {
		my $act = shift;
		my $old = lc $act->{dst}->homenick();
		my $new = lc $act->{nick};
		return 1 if $old eq $new;
		undef;
		# Not transmitting case changes is the easiset way to do it
		# If this is ever changed: the local network's bookkeeping is easy
		# remote networks could have this nick tagged; they can untag but 
		# only if they can assure that it is impossible to be collided
	}, NICK => act => sub {
		my $act = $_[0];
		my $nick = $act->{dst};
		my $old = $homenick{$$nick};
		my $new = $act->{nick};

		$ts{$$nick} = $act->{nickts} if $act->{nickts};
		$homenick{$$nick} = $new;
		for my $id (keys %{$nets{$$nick}}) {
			my $net = $nets{$$nick}->{$id};
			next if $net->jlink();
			my $from = $nicks{$$nick}->{$id};
			my $to = $net->request_nick($nick, $new);
			$net->release_nick($from);
			$nicks{$$nick}->{$id} = $to;
	
			$act->{from}->{$id} = $from;
			$act->{to}->{$id} = $to;
		}
	}, NICKINFO => act => sub {
		my $act = $_[0];
		my $nick = $act->{dst};
		$info{$$nick}{$act->{item}} = $act->{value};
	}, UMODE => act => sub {
		my $act = $_[0];
		my $nick = $act->{dst};
		for my $ltxt (@{$act->{mode}}) {
			if ($ltxt =~ /\+(.*)/) {
				$mode{$$nick}->{$1} = 1;
			} elsif ($ltxt =~ /-(.*)/) {
				delete $mode{$$nick}->{$1};
			} else {
				warn "Bad umode change $ltxt";
			}
		}
	}, QUIT => cleanup => sub {
		my $act = $_[0];
		my $nick = $act->{dst};
		for my $id (keys %{$chans{$$nick}}) {
			my $chan = $chans{$$nick}->{$id};
			$chan->part($nick);
		}
		for my $id (keys %{$nets{$$nick}}) {
			my $net = $nets{$$nick}->{$id};
			next if $net->jlink();
			my $name = $nicks{$$nick}->{$id};
			$net->release_nick($name);
		}
	}, JOIN => act => sub {
		my $act = shift;
		my $nick = $act->{src};
		my $chan = $act->{dst};

		my $name = $chan->str($homenet{$$nick});
		$chans{$$nick}->{lc $name} = $chan;

		return if $homenet{$$nick}->jlink();
		
		for my $net ($chan->nets()) {
			next if $nets{$$nick}->{$net->id()};
			Janus::insert(+{
				type => 'CONNECT',
				dst => $nick,
				net => $net,
			});
		}
	}, PART => cleanup => sub {
		my $act = $_[0];
		my $nick = $act->{src};
		my $chan = $act->{dst};
		$nick->_part($chan);
	}, KICK => cleanup => sub {
		my $act = $_[0];
		my $nick = $act->{kickee};
		my $chan = $act->{dst};
		$nick->_part($chan);
	}, KILL => act => sub {
		my $act = shift;
		my $nick = $act->{dst};
		my $net = $act->{net};
		for my $chan (values %{$chans{$$nick}}) {
			next unless $chan->is_on($net);
			my $act = {
				type => 'KICK',
				src => $act->{src},
				dst => $chan,
				kickee => $nick,
				msg => $act->{msg},
				except => $net,
				nojlink => 1,
			};
			$act->{sendto} = [ $chan->sendto($act, $net) ];
			Janus::append($act);
		}
	}, KILL => cleanup => sub {
		my $act = shift;
		my $nick = $act->{dst};
		my $net = $act->{net};
		$nick->_netpart($net);
	});
}

} 1;
