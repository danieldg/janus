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

sub umode {
	my $n = shift;
	local $_;
	my %m = map { $_ => 1 } split //, ($n->{umode} || '');
	my $pm = '+';
	for (split //, shift) {
		if (/[+-]/) {
			$pm = $_;
		} elsif ($pm eq '+') {
			$m{$_} = 1;
		} elsif ($pm eq '-') {
			delete $m{$_};
		}
	}
	$n->{umode} = join '', sort keys %m;
}

# send to all but possibly one network for NICKINFO
# send to home network for MSG
sub send {
	my($nick, $except, $act) = @_;
	$except = $except ? $except->id() : 0;
	if ($act->{type} eq 'MSG') {
		$nick->{homenet}->send($act);
	} else {
		for my $id (keys %{$nick->{nets}}) {
			next if $id eq $except;
			$nick->{nets}->{$id}->send($act);
		}
	}
}

sub regex {
	0;
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

sub connect {
	my($nick, $net) = @_;
	my $id = $net->id();
	return if exists $nick->{nets}->{$id};
	my $rnick = $net->request_nick($nick, $nick->{homenick});
	$nick->{nets}->{$id} = $net;
	$nick->{nicks}->{$id} = $rnick;
	$net->send({
		type => 'CONNECT',
		src => $nick,
		dst => $net,
		expire => 0,
	});
}

sub _join {
	my($nick,$chan) = @_;
	my $name = $chan->str($nick->{homenet});
	$nick->{chans}->{$name} = $chan;
}

sub _part {
	my($nick,$chan) = @_;
	my $name = $chan->str($nick->{homenet});
	delete $nick->{chans}->{$name};
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

my %actions = (
	NICK => sub {
		my($nick,$act) = @_;
		my $old = $nick->{homenick};
		my $new = $act->{nick};
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
	},
);

sub act {
	my($nick, $act) = @_;
	my $type = $act->{type};
	return $act unless exists $actions{$type};
	$actions{$type}->(@_);
}

sub postact {
	my($nick, $act) = @_;
	return unless $act->{type} eq 'QUIT';
	
	for my $id (keys %{$nick->{chans}}) {
		my $chan = $nick->{chans}->{$id};
		$chan->part($nick);
	}
	for my $id (keys %{$nick->{nets}}) {
		my $net = $nick->{nets}->{$id};
		my $name = $nick->{nicks}->{$id};
		$net->release_nick($name);
	}
}

1;
