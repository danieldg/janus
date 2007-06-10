# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Nick; {
use Object::InsideOut;
use strict;
use warnings;
use Scalar::Util 'weaken';

my @gid :Field :Get(gid);
my @homenet :Field :Get(homenet);
my @homenick :Field :Get(homenick);
my @nets :Field;
my @nicks :Field;
my @chans :Field;
my @mode :Field;
my @info :Field;
my @ts :Field :Get(ts);

my %initargs :InitArgs = (
	gid => '',
	net => '',
	nick => '',
	ts => '',
	info => '',
	mode => '',
);

sub _init :Init {
	my($nick, $ifo) = @_;
	my $net = $ifo->{net};
	my $gid = $ifo->{gid} || $net->id() . ':' . $$nick;
	$gid[$$nick] = $gid;
	$Janus::gnicks{$gid} = $nick;
	$homenet[$$nick] = $net;
	$homenick[$$nick] = $ifo->{nick};
	my $homeid = $net->id();
	$nets[$$nick] = { $homeid => $net };
	$nicks[$$nick] = { $homeid => $ifo->{nick} };
	$ts[$$nick] = $ifo->{ts} || time;
	$info[$$nick] = $ifo->{info} || {};
	$mode[$$nick] = $ifo->{mode} || {};
	# prevent mode bouncing
	$mode[$$nick]{oper} = 1 if $mode[$$nick]{service};
}

sub to_ij {
	my($nick, $ij) = @_;
	local $_;
	my $out = '';
	$out .= ' gid='.$ij->ijstr($gid[$$nick]);
	$out .= ' net='.$ij->ijstr($homenet[$$nick]);
	$out .= ' nick='.$ij->ijstr($homenick[$$nick]);
	$out .= ' ts='.$ij->ijstr($ts[$$nick]);
	$out .= ' mode='.$ij->ijstr($mode[$$nick]);
	$out .= ' info=';
	my %sinfo;
	$sinfo{$_} = $info[$$nick]{$_} for 
		qw/ident host vhost ip name away swhois/;
	$out . $ij->ijstr(\%sinfo);
}

sub _destroy :Destroy {
	my $n = $_[0];
	print "   NICK: $n $homenick[$$n] deallocated\n";
}

# send to all but possibly one network for NICKINFO
# send to home network for MSG
sub sendto {
	my($nick, $act, $except) = @_;
	if ($act->{type} eq 'MSG' || $act->{type} eq 'WHOIS') {
		return $homenet[$$nick];
	} elsif ($act->{type} eq 'CONNECT' || $act->{type} eq 'RECONNECT') {
		return $act->{net};
	} else {
		my %n = %{$nets[$$nick]};
		delete $n{$except->id()} if $except;
		return values %n;
	}
}

sub is_on {
	my($nick, $net) = @_;
	return exists $nets[$$nick]{$net->id()};
}

sub has_mode {
	my $nick = $_[0];
	return $mode[$$nick]->{$_[1]};
}

sub umodes {
	my $nick = $_[0];
	return sort keys %{$mode[$$nick]};
}

sub jlink {
	return $homenet[${$_[0]}]->jlink();
}

# vhost, ident, etc
sub info {
	my $nick = $_[0];
	$info[$$nick]{$_[1]};
}

sub rejoin {
	my($nick,$chan) = @_;
	my $name = $chan->str($homenet[$$nick]);
	$chans[$$nick]{lc $name} = $chan;

	return if $nick->jlink();
		
	for my $net ($chan->nets()) {
		next if $nets[$$nick]->{$net->id()};
		&Janus::insert(+{
			type => 'CONNECT',
			dst => $nick,
			net => $net,
		});
	}
}

sub _part {
	my($nick,$chan) = @_;
	my $name = $chan->str($homenet[$$nick]);
	delete $chans[$$nick]->{lc $name};
	$nick->_netclean($chan->nets());
}

sub _netpart {
	my($nick, $net) = @_;	
	my $id = $net->id();

	delete $nets[$$nick]->{$id};
	return if $net->jlink();
	my $rnick = delete $nicks[$$nick]{$id};
	$net->release_nick($rnick);
}

sub _netclean {
	my $nick = shift;
	return if $info[$$nick]{_is_janus};
	my %leave = @_ ? map { $_->id() => $_ } @_ : %{$nets[$$nick]};
	delete $leave{$homenet[$$nick]->id()};
	for my $chan (values %{$chans[$$nick]}) {
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

sub lid {
	my $nick = $_[0];
	return $$nick;
}

sub str {
	my($nick,$net) = @_;
	$nicks[$$nick]{$net->id()};
}

sub modload {
 my $me = shift;
 Janus::hook_add($me, 
	CONNECT => act => sub {
		my $act = shift;
		my $nick = $act->{dst};
		my $net = $act->{net};
		my $id = $net->id();
		if (exists $nets[$$nick]{$id}) {
			warn "Nick alredy on CONNECTing network!";
		}
		$nets[$$nick]{$id} = $net;
		return if $net->jlink();

		my $rnick = $net->request_nick($nick, $homenick[$$nick], 0);
		$nicks[$$nick]->{$id} = $rnick;
	}, RECONNECT => act => sub {
		my $act = shift;
		my $nick = $act->{dst};
		my $net = $act->{net};
		my $id = $net->id();
		
		delete $act->{except};

		my $from = $act->{from} = $nicks[$$nick]{$id};
		my $to = $act->{to} = $net->request_nick($nick, $homenick[$$nick], 1);
		$net->release_nick($from);
		$nicks[$$nick]{$id} = $to;
		
		if ($act->{killed}) {
			$act->{reconnect_chans} = [ values %{$chans[$$nick]} ];
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
		my $old = $homenick[$$nick];
		my $new = $act->{nick};

		$ts[$$nick] = $act->{nickts} if $act->{nickts};
		for my $id (keys %{$nets[$$nick]}) {
			my $net = $nets[$$nick]->{$id};
			next if $net->jlink();
			my $from = $nicks[$$nick]->{$id};
			my $to = $net->request_nick($nick, $new);
			$net->release_nick($from);
			$nicks[$$nick]->{$id} = $to;
	
			$act->{from}->{$id} = $from;
			$act->{to}->{$id} = $to;
		}
	}, NICK => cleanup => sub {
		my $act = $_[0];
		my $nick = $act->{dst};
		$homenick[$$nick] = $act->{nick};
	}, NICKINFO => act => sub {
		my $act = $_[0];
		my $nick = $act->{dst};
		$info[$$nick]{$act->{item}} = $act->{value};
	}, UMODE => act => sub {
		my $act = $_[0];
		my $nick = $act->{dst};
		for my $ltxt (@{$act->{mode}}) {
			if ($ltxt =~ /\+(.*)/) {
				$mode[$$nick]->{$1} = 1;
			} elsif ($ltxt =~ /-(.*)/) {
				delete $mode[$$nick]->{$1};
			} else {
				warn "Bad umode change $ltxt";
			}
		}
	}, QUIT => cleanup => sub {
		my $act = $_[0];
		my $nick = $act->{dst};
		for my $id (keys %{$chans[$$nick]}) {
			my $chan = $chans[$$nick]->{$id};
			$chan->part($nick);
		}
		for my $id (keys %{$nets[$$nick]}) {
			my $net = $nets[$$nick]->{$id};
			next if $net->jlink();
			my $name = $nicks[$$nick]->{$id};
			$net->release_nick($name);
		}
		delete $Janus::gnicks{$nick->gid()};
	}, JOIN => act => sub {
		my $act = shift;
		my $nick = $act->{src};
		my $chan = $act->{dst};

		my $name = $chan->str($homenet[$$nick]);
		$chans[$$nick]->{lc $name} = $chan;

		return if $homenet[$$nick]->jlink();
		
		for my $net ($chan->nets()) {
			next if $nets[$$nick]->{$net->id()};
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
		for my $chan (values %{$chans[$$nick]}) {
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
			&Janus::append($act);
		}
	}, KILL => cleanup => sub {
		my $act = shift;
		my $nick = $act->{dst};
		my $net = $act->{net};
		$nick->_netpart($net);
	});
}

} 1;
