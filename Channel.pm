package Channel;
use Nick;
use Scalar::Util qw(weaken);
use strict;
use warnings;

sub new {
	my($class,$net,$name) = @_;
	my %chash; my $chan = \%chash;
	my $id = $net->id();
	weaken($chan->{nets}->{$id} = $net);
	$chan->{names}->{$id} = $name;
	bless $chan, $class;
}

sub _kick_kline {
	my($chan, $nick, $dst, $line) = @_;
	$dst->send(+{
		type => 'KICK',
		src => $line->{net},
		dst => $chan,
		kickee => $nick,
		reason => "K:lined by $line->{net}->{netname} ($line->{reason})",
	});
}

sub _ljoin {
	my($nick, $chan, $src, $nets) = @_;
	my $id = $nick->id();
	
	for my $net (values %$nets) {
		my $line = $nick->is_klined($net);
		if ($line) {
			$src->part($nick);
			for $net (values %{$src->{nets}}) {
				$chan->_kick_kline($nick, $net, $line);
			}
			return 0;
		}
	}
	for my $net (values %$nets) {
		$nick->connect($net);
	}
	$nick->_join($chan);

	my $mode = $src->{nmode}->{$id};
	$chan->{nicks}->{$id} = $nick;
	$chan->{nmode}->{$id} = $mode;
	for my $net (values %$nets) {
		$net->send(+{
			type => 'JOIN',
			src => $nick,
			dst => $chan,
			mode => $mode,
		});
	}
	1;
}

sub _mergenet {
	my($chan, $src) = @_;
	for my $id (keys %{$src->{nets}}) {
		my $net = $src->{nets}->{$id};
		my $name = $src->{names}->{$id};
		$chan->{nets}->{$id} = $net;
		$chan->{names}->{$id} = $name;
		$net->{chans}->{lc $name} = $chan;
	}
}

sub link {
	my($chan1,$chan2) = @_;
	
	for my $id (keys %{$chan1->{nets}}) {
		return 0 if exists $chan2->{nets}->{$id};
	}
	
	my %chanh;
	my $chan = \%chanh;
	bless $chan;
	$chan->{ts} = $chan1->{ts};
	$chan->_mergenet($chan1);
	$chan->_mergenet($chan2);

	# TODO merge in the modes, decide on a topic; use timestamps on all this

	for my $nick (values %{$chan1->{nicks}}) {
		_ljoin $nick, $chan, $chan1, $chan2->{nets};
	}
	for my $nick (values %{$chan2->{nicks}}) {
		_ljoin $nick, $chan, $chan2, $chan1->{nets};
	}
	1;
}

sub delink {
	my($chan, $net) = @_;
	my $id = $net->id();
	return unless exists $chan->{nets}->{$id};
	my %chanh;
	my $split = \%chanh;
	bless $split;

	$split->{nets}->{$id} = delete $chan->{nets}->{$id};
	my $name = $split->{names}->{$id} = delete $chan->{names}->{$id};
	$net->{chans}->{lc $name} = $split;

	$split->{ts} = $chan->{ts}; # TODO also copy modes, topic
	for my $nid (keys %{$chan->{nicks}}) {
		if ($chan->{nicks}->{$nid}->{homenet}->id() eq $id) {
			my $nick = $split->{nicks}->{$nid} = delete $chan->{nicks}->{$nid};
			$split->{nmode}->{$nid} = delete $chan->{nmode}->{$nid};
			$chan->send($net, +{
				type => 'PART',
				src => $nick,
				dst => $chan,
				msg => 'Channel delinked',
			});
		} else {
			my $nick = $chan->{nicks}->{$nid};
			$split->send(undef, +{
				type => 'PART',
				src => $nick,
				dst => $split,
				msg => 'Channel delinked',
			});
		}
	}
}

# get name on a network
sub str {
	my($chan,$net) = @_;
	$chan->{names}->{$net->id()};
}

sub id { die }

# send to all but possibly one network
sub send {
	my($chan, $except, $act) = @_;
	$except = $except ? $except->id() : 0;
	for my $id (keys %{$chan->{nets}}) {
		next if $id eq $except;
		$chan->{nets}->{$id}->send($act);
	}
}

sub try_join {
	my($chan,$nick) = @_;
	for my $id (keys %{$chan->{nets}}) {
		my $net = $chan->{nets}->{$id};
		my $bounce = $nick->is_klined($net);
		if ($bounce) {
			$chan->_kick_kline($nick, $nick->{homenet}, $bounce);
			return 0;
		}
	}
	for my $id (keys %{$chan->{nets}}) {
		my $net = $chan->{nets}->{$id};
		$nick->connect($net);
	}
	$chan->{nicks}->{$nick->id()} = $nick;
	$nick->_join($chan);
	1;
}

sub part {
	my($chan,$nick) = @_;
	delete $chan->{nicks}->{$nick->id()};
	delete $chan->{nmode}->{$nick->id()};
	$nick->_part($chan);
}

sub timesync {
	my($chan, $ts) = @_;
	$chan->{ts} = $ts;
	# TODO wipe modes if older $ts given
}

my %actions = (
	JOIN => sub {
		my($chan, $act) = @_;
		my $nick = $act->{src};
		return unless $act->{mode};
		$chan->{nmode}->{$nick->id()} = $act->{mode};
	}, PART => sub {
		my($chan, $act) = @_;
		my $nick = $act->{src};
		$chan->part($nick);
	}, MODE => sub {
		# TODO
	}, BAN => sub {
		# TODO
	},
);

sub act {
	my($chan, $act) = @_;
	my $type = $act->{type};
	return unless exists $actions{$type};
	$actions{$type}->(@_);
}

sub postact {
}
