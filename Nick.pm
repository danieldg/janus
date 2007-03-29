package Nick;
use strict;
use warnings;
use Scalar::Util 'weaken';

sub new {
	my $class = (@_ % 2) ? shift : 'Nick';
	my %nhash = @_;
	my $nick = \%nhash;
	my $homeid = $nick->{homenet}->id();
	$nick->{nets} = { $homeid => $nick->{homenet} };
	$nick->{nicks} = { $homeid => $nick->{homenick} };
	bless $nick, $class;
}

sub DESTROY {
	print "DBG: $_[0] deallocated\n";
}

sub umode {
	my $nick = shift;
	my $net = $nick->{homenet};
	local $_;
	my $pm = '+';
	for (split //, shift) {
		my $txt = $net->{umode2txt}->{$_};
		if (/[+-]/) {
			$pm = $_;
		} elsif ($pm eq '+') {
			$nick->{mode}->{$txt} = 1;
		} elsif ($pm eq '-') {
			delete $nick->{mode}->{$txt};
		}
	}
}

# send to all but possibly one network for NICKINFO
# send to home network for MSG
sub sendto {
	my($nick, $act, $except) = @_;
	if ($act->{type} eq 'MSG') {
		my $net = $nick->{homenet};
		return $net if exists $act->{src}->{nets}->{$net->id()};
		return ();
	} else {
		my %n = %{$nick->{nets}};
		delete $n{$except->id()} if $except;
		return values %n;
	}
}

sub is_klined {
	my($nick, $net) = @_;
	return undef if exists $nick->{nets}->{$net->id()};
		# we are not klined if we're already in
	for my $line (@{$net->{klines}}) {
		return $line if $line->match($nick);
	}
	undef;
}

sub is_on {
	my($nick, $net) = @_;
	return exists $nick->{nets}->{$net->id()};
}

sub connect {
	my($nick, $net) = @_;
	my $id = $net->id();
	return () if exists $nick->{nets}->{$id};
	my $rnick = $net->request_nick($nick, $nick->{homenick});
	$nick->{nets}->{$id} = $net;
	$nick->{nicks}->{$id} = $rnick;
	return +{
		type => 'CONNECT',
		src => $nick,
		dst => $net,
	};
}

sub _join {
	my($nick,$chan) = @_;
	my $name = $chan->str($nick->{homenet});
	$nick->{chans}->{lc $name} = $chan;
}

sub _part {
	my($nick,$chan) = @_;
	my $name = $chan->str($nick->{homenet});
	delete $nick->{chans}->{lc $name};
	$nick->_netclean(%{$chan->{nets}});
}

sub _netclean {
	my $nick = shift;
	my %nets = @_ ? @_ : %{$nick->{nets}};
	delete $nets{$nick->{homenet}->id()};
	for my $chan (values %{$nick->{chans}}) {
		for my $id (keys %{$chan->{nets}}) {
			delete $nets{$id};
		}
	}
	for my $id (keys %nets) {
		my $net = $nets{$id};
		$net->send({
			type => 'QUIT',
			src => $nick,
			dst => $nick,
			msg => 'Left all shared channels',
		});
		delete $nick->{nets}->{$id};
		my $rnick = delete $nick->{nicks}->{$id};
		$net->release_nick($rnick);
	}
}

sub id {
	my $nick = $_[0];
	return $nick->{homenet}->id() . '~' . $nick->{homenick};
}

sub str {
	my($nick,$net) = @_;
	$nick->{nicks}->{$net->id()};
}

sub vhost {
	my $nick = $_[0];
	my $net = $nick->{homenet};
	$net->vhost($nick);
}

sub modload {
	my($me, $janus) = @_;
	$janus->hook_add($me, 
		NICK => act => sub {
			my $act = shift;
			my $nick = $act->{dst};
			my $old = $nick->{homenick};
			my $new = $act->{nick};
			return () if (lc $old) eq (lc $new);
			# Not transmitting case changes is the easiset way to do it
			# If this is ever changed: the local network's bookkeeping is easy
			# remote networks could have this nick tagged; they can untag but 
			# only if they can assure that it is impossible to be collided

			$nick->{nickts} = $act->{nickts} if $act->{nickts};
			$nick->{homenick} = $new;
			for my $id (keys %{$nick->{nets}}) {
				my $net = $nick->{nets}->{$id};
				my $from = $nick->{nicks}->{$id};
				my $to = $net->request_nick($nick, $new);
				$net->release_nick($from);
				$nick->{nicks}->{$id} = $to;
		
				$act->{from}->{$id} = $from;
				$act->{to}->{$id} = $to;
			}
			undef;
		}, NICKINFO => act => sub {
			my $act = shift;
			my $nick = $act->{dst};
			$nick->{$act->{item}} = $act->{value};
			undef;
		}, UMODE => act => sub {
			my $act = shift;
			my $nick = $act->{dst};
			$nick->umode($act->{value});
			undef;
		}, QUIT => cleanup => sub {
			my $act = shift;
			my $nick = $act->{dst};
			for my $id (keys %{$nick->{chans}}) {
				my $chan = $nick->{chans}->{$id};
				$chan->_part($nick);
			}
			for my $id (keys %{$nick->{nets}}) {
				my $net = $nick->{nets}->{$id};
				my $name = $nick->{nicks}->{$id};
				$net->release_nick($name);
			}
			undef;
		}, PART => cleanup => sub {
			my $act = shift;
			my $nick = $act->{src};
			my $chan = $act->{dst};
			$nick->_part($chan);
		}, KICK => cleanup => sub {
			my $act = shift;
			my $nick = $act->{kickee};
			my $chan = $act->{dst};
			$nick->_part($chan);
		},
	);
}

1;
