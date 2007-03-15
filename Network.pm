package Network;
use Channel;
use Scalar::Util qw(weaken);
use IO::Socket::INET;

sub new {
	my $class = shift;
	my %neth = @_;
	my $net = \%neth;
	bless $net, $class;
}

sub connect {
	my $net = shift;
	if (@_) {
		$net->{sock} = shift;
		$net->intro(1);
	} else {
		my $sock = IO::Socket::INET->new(
			PeerAddr => $net->{linkaddr},
			PeerPort => $net->{linkport},
		) or return 0;
		$sock->autoflush(1);
		$net->{sock} = $sock;
		$net->intro(0);
	}
	$net->{recvq} = '';
	1;
}

sub id {
	return $_[0]->{id};
}

sub nick {
	my($net, $name) = @_;
	$net->{nicks}->{$name};
}

sub chan {
	my($net, $name, $new) = @_;
	unless (exists $net->{chans}->{$name}) {
		warn unless $new;
		my $id = $net->{id};
		$net->{chans}->{$name} = Channel->new($net, $name);
	}
	$net->{chans}->{$name};
}

sub str {
	$_[0]->{id};
}

################################################################################
# Basic Actions
################################################################################

# Request a nick on a remote network (CONNECT/JOIN must be sent AFTER this)
sub request_nick {
	my($net, $nick, $reqnick) = @_;
	if (exists $net->{nicks}->{$reqnick}) {
		my $tag = '/'.$nick->{homenet}->id();
		$reqnick = substr($reqnick, 0, 30 - length $tag) . $tag;
		if (exists $net->{nicks}->{$reqnick}) {
			warn "Collision with tagged nick"; # TODO kill or change tag
		}
	}
	$net->{nicks}->{$reqnick} = $nick;
	return $reqnick;
}

# Release a nick on a remote network (PART/QUIT must be sent BEFORE this)
sub release_nick {
	my($net, $req) = @_;
	delete $net->{nicks}->{$req};
}

1;
