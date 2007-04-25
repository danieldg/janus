package Ban; {
use Object::InsideOut;
use strict;
use warnings;

my %netbans;
my @regex  :Field              :Get(regex);
my @expr   :Field :Arg(expr)   :Get(expr);
my @net    :Field :Arg(net)    :Get(net);
my @setter :Field :Arg(setter) :Get(setter);
my @expire :Field :Arg(expire) :Get(expire);
my @reason :Field :Arg(reason) :Get(reason);

sub add {
	my $ban = Ban->new(@_);
	push @{$netbans{$ban->net()->id()}}, $ban;
	$ban;
}

sub find {
	my($net, $iexpr) = @_;
	for my $ban (@{$netbans{$net->id()}}) {
		$expr[$$ban] eq $iexpr and return $ban;
	}
	undef;
}

sub _init :Init {
	my $ban = shift;
	local $_ = $ban->expr();
	unless (s/^~//) { # all expressions starting with a ~ are raw perl regexes
		s/(\W)/\\$1/g;
		s/\\\?/./g;  # ? matches one char...
		s/\\\*/.*/g; # * matches any chars...
	}
	$regex[$$ban] = qr/^$_$/i; # compile the regex now for faster matching later
}

sub banlist {
	my $net = shift;
	my @list = @{$netbans{$net->id()} || []};
	my @good;
	for my $ban (@list) {
		my $exp = $expire[$$ban];
		unless ($exp && $exp < time) {
			push @good, $ban;
		}
	}
	$netbans{$net->id()} = \@good;
	@good;
}

sub delete {
	my $ban = shift;
	$expire[$$ban] = 1;
}

sub match {
	my($ban, $nick) = @_;
	my $mask = ref $nick ? 
		$nick->homenick().'!'.$nick->info('ident').'@'.$nick->info('host').'%'.$nick->homenet()->id().':'.$nick->info('name') :
		$nick;
	$mask =~ /$regex[$$ban]/;
}

sub modload {
 my $me = shift;
 Janus::hook_add($me,
	CONNECT => check => sub {
		my $act = shift;
		my $nick = $act->{dst};
		my $net = $act->{net};
		return undef if $net->jlink() || $act->{reconnect};

		my $mask = $nick->homenick().'!'.$nick->info('ident').'@'.$nick->info('host').'%'.$nick->homenet()->id().':'.$nick->info('name');
		for my $ban (banlist($net)) {
			next unless $ban->match($mask);
			Janus::append(+{
				type => 'KILL',
				dst => $nick,
				net => $net,
				msg => "Banned by ".$net->netname().": $reason[$$ban]",
			});
			return 1;
		}
		undef;
	}, NETSPLIT => act => sub {
		my $act = shift;
		my $net = $act->{net};
		delete $netbans{$net->id()};
	});
}

} 1;
