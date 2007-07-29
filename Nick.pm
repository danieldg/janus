# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Nick;
use strict;
use warnings;
use Persist;
use Object::InsideOut;
use Scalar::Util 'weaken';

=head1 Nick

Object representing a nick that exists across several networks

=over

=cut

__PERSIST__
persist @gid      :Field :Get(gid);
persist @homenet  :Field :Get(homenet);
persist @homenick :Field :Get(homenick);
persist @nets     :Field;
persist @nicks    :Field;
persist @chans    :Field;
persist @mode     :Field;
persist @info     :Field;
persist @ts       :Field :Get(ts);

__CODE__

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
	$out . $ij->ijstr($info[$$nick]);
}

sub _destroy :Destroy {
	my $n = $_[0];
	print "   NICK:$$n $n $homenick[$$n] deallocated\n";
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

=item $nick->is_on($net)

return true if the nick is on the given network

=cut

sub is_on {
	my($nick, $net) = @_;
	return exists $nets[$$nick]{$net->id()};
}

=item $nick->netlist() 

return the list of all networks this nick is currently on

=cut

sub netlist {
	my $nick = $_[0];
	return values %{$nets[$$nick]};
}

=item $nick->has_mode($mode)

return true if the nick has the given umode

=cut

sub has_mode {
	my $nick = $_[0];
	return $mode[$$nick]->{$_[1]};
}

=item $nick->umodes()

returns the (sorted) list of umodes that this nick has set

=cut

sub umodes {
	my $nick = $_[0];
	return sort keys %{$mode[$$nick]};
}

=item $nick->jlink()

returns the InterJanus link if this nick is remote, or undef if it is local

=cut

sub jlink {
	return $homenet[${$_[0]}]->jlink();
}

=item $nick->info($item)

information about this nick. Defined global info fields: 
	host ident ip name vhost away swhois

Locally, more info may be defined by the home Network; this should
be for use only by that local network

=cut

sub info {
	my $nick = $_[0];
	$info[$$nick]{$_[1]};
}

=item $nick->rejoin($chan)

Connecting to all networks that the given channel is on
(used when linking channels)

=cut

sub rejoin {
	my($nick,$chan) = @_;
	my $name = $chan->str($homenet[$$nick]);
	$chans[$$nick]{lc $name} = $chan;

	return if $nick->jlink();

	for my $net ($chan->nets()) {
		next if $nets[$$nick]->{$net->id()};
		&Janus::append(+{
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
}

sub _netpart {
	my($nick, $net) = @_;	
	my $id = $net->id();

	delete $nets[$$nick]->{$id};
	return if $net->jlink();
	my $rnick = delete $nicks[$$nick]{$id};
	$net->release_nick($rnick);
	# this could be the last local network the nick was on
	# if so, we need to remove it from Janus::gnicks
	my $jl = $nick->jlink();
	return unless $jl;
	for my $net (values %{$nets[$$nick]}) {
		my $njl = $net->jlink();
		return unless $njl && $njl eq $jl;
	}
	delete $Janus::gnicks{$nick->gid()};
}

=item $nick->lid()

Locally unique ID for this nick (unique for the lifetime of the nick only)

=cut

sub lid {
	my $nick = $_[0];
	return $$nick;
}

=item $nick->str($net)

Get the nick's name on the given network

=cut

sub str {
	my($nick,$net) = @_;
	$nicks[$$nick]{$net->id()};
}

=back

=cut

&Janus::hook_add(
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
		# TODO Not transmitting case changes is the easiset way to do it
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
	},
);

1;
