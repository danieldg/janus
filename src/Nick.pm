# Copyright (C) 2007-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Nick;
use strict;
use warnings;
use integer;
use Persist;
use Scalar::Util 'weaken';

=head1 Nick

Object representing a nick that exists across several networks

=over

=item $nick->gid()

Globally unique identifier for this nick. Format is currently jname:netid:nickid

=item $nick->homenet()

Home network object for this nick.

=item $nick->homenick()

String of the home nick of this user

=item $nick->ts($net)

Last nick-change timestamp of this user on the given network

=cut

our(@gid, @homenet, @homenick, @nets, @nicks, @nickts, @chans, @mode, @info);
Persist::register_vars(qw(gid homenet homenick nets nicks nickts chans mode info));
Persist::autoget(qw(gid homenet homenick));

our %umodebit;
do {
	my $i = 1;
	for (values %umodebit) {
		$i = 2*$_ if $_ >= $i;
	}
	for (qw/
		oper ssl colorstrip
		invisible wallops bot badword hide_chans
		dcc_reject deaf_chan deaf_regpriv deaf_ctcp deaf_commonchan no_privmsg callerid
		hideoper no_kick whois_notice
	/) {
		next if $umodebit{$_};
		$umodebit{$_} = $i;
		$i *= 2;
	}
	warn "Too many umode bits for a scalar" if (sprintf '%x', $i) =~ /f/;
	# Note: if this ever happens, convert to using vec() on a bitstring
};

sub _init {
	my($nick, $ifo) = @_;
	my $net = $ifo->{net};
	my $gid = $ifo->{gid} || $net->next_nickgid();
	$gid[$$nick] = $gid;
	$homenet[$$nick] = $net;
	$homenick[$$nick] = $ifo->{nick};
	$nets[$$nick] = { $$net => $net };
	$nicks[$$nick] = { $$net => $ifo->{nick} };
	$nickts[$$nick] = { $$net => $ifo->{ts} };
	$chans[$$nick] = [];
	$info[$$nick] = $ifo->{info} || {};
	for (qw/host vhost ident/) {
		$info[$$nick]{$_} =~ s/(?:\003\d{0,2}(?:,\d{1,2})?|[\001\002\004-\037])//g;
	}
	$mode[$$nick] = 0;
	if ($ifo->{mode}) {
		for (keys %{$ifo->{mode}}) {
			$mode[$$nick] |= $umodebit{$_};
		}
	}
	# prevent mode bouncing
	$mode[$$nick] |= $umodebit{oper} if $mode[$$nick] & $umodebit{service};
	($gid, $homenick[$$nick]);
}

sub to_ij {
	my($nick, $ij) = @_;
	local $_;
	my $out = '';
	my $m = $mode[$$nick];
	my %mode;
	for (keys %umodebit) {
		$mode{$_}++ if $m & $umodebit{$_};
	}
	$out .= ' gid='.$ij->ijstr($gid[$$nick]);
	$out .= ' net='.$ij->ijstr($homenet[$$nick]);
	$out .= ' nick='.$ij->ijstr($homenick[$$nick]);
	$out .= ' mode='.$ij->ijstr(\%mode);
	$out .= ' info=';
	$out . $ij->ijstr($info[$$nick]);
}

sub _destroy {
	my $n = $_[0];
	($gid[$$n], $homenick[$$n]);
}

# send to all but possibly one network for NICKINFO
# send to home network for MSG
sub sendto {
	my($nick, $act, $except) = @_;
	if ($act->{type} eq 'MSG' || $act->{type} eq 'WHOIS' || $act->{type} eq 'INVITE') {
		return $homenet[$$nick];
	} elsif ($act->{type} eq 'CONNECT' || $act->{type} eq 'RECONNECT') {
		return $act->{net};
	} else {
		my %n = %{$nets[$$nick]};
		delete $n{$$except} if $except;
		return values %n;
	}
}

=item $nick->is_on($net)

return true if the nick is on the given network

=cut

sub is_on {
	my($nick, $net) = @_;
	return exists $nets[$$nick]{$$net};
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
	my $b = $umodebit{$_[1]} or do {
		warn "Unknown umode $_[1]";
		return 0;
	};
	return $mode[$$nick] & $b;
}

=item $nick->umodes()

returns the (sorted) list of umodes that this nick has set

=cut

sub umodes {
	my $nick = $_[0];
	my $m = $mode[$$nick];
	my @r;
	for (sort keys %umodebit) {
		push @r, $_ if $m & $umodebit{$_};
	}
	@r;
}

=item $nick->all_chans()

returns the list of all channels the nick is on

=cut

sub all_chans {
	my $nick = $_[0];
	return @{$chans[$$nick]};
}

=item $nick->jlink()

returns the InterJanus link if this nick is remote, or undef if it is local

=cut

sub jlink {
	my $net = $homenet[${$_[0]}];
	$net ? $net->jlink() : undef;
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

=item $nick->realhostmask()

The real nick!user@host of the user (i.e. not vhost)

=cut

sub realhostmask {
	my $n = $_[0];
	$homenick[$$n].'!'.$info[$$n]{ident}.'@'.$info[$$n]{host};
}

sub vhostmask {
	my $n = $_[0];
	$homenick[$$n].'!'.$info[$$n]{ident}.'@'.$info[$$n]{vhost};
}

sub netnick {
	my $n = $_[0];
	$homenet[$$n]->name . ':' . $homenick[$$n];
}

=item $nick->rejoin($chan)

Connecting to all networks that the given channel is on
(used when linking channels)

=cut

sub rejoin {
	my($nick,$chan,$from) = @_;
	my $hn = $homenet[$$nick];
	my %clist;
	$clist{$_->lstr($hn)} = $_ for @{$chans[$$nick]};
	delete $clist{$from->lstr($hn)} if $from && $from->is_on($hn);
	$clist{$chan->lstr($hn)} = $chan;
	$chans[$$nick] = [ values %clist ];


	return if $nick->jlink || $nick->info('noquit');

	for my $net ($chan->nets()) {
		next if $nets[$$nick]{$$net};
		Event::insert_partial(+{
			type => 'CONNECT',
			dst => $nick,
			net => $net,
			'for' => $chan,
		});
	}
}

sub _netpart {
	my($nick, $net) = @_;

	return unless delete $nets[$$nick]{$$net};
	return if $net->jlink();
	my $rnick = delete $nicks[$$nick]{$$net};
	$net->release_nick($rnick, $nick);
	# this could be the last local network the nick was on
	# if so, we need to remove it from Janus::gnicks
	my $jl = $nick->jlink();
	return unless $jl;
	$jl = $jl->parent() while $jl->parent();
	for my $net (values %{$nets[$$nick]}) {
		next if $net == $Interface::network;
		return unless $jl->jparent($net);
	}
	Event::append({
		type => 'POISON',
		item => $nick,
		reason => 'final netpart',
	});
	delete $Janus::gnicks{$nick->gid()};
}

sub _netclean {
	my $nick = shift;
	return if $nick->info('noquit') || $Janus::lmode eq 'Bridge';

	my $home = $nick->homenet;
	my %leave = @_ ? map { $$_ => $_ } @_ : %{$nets[$$nick]};
	delete $leave{${$homenet[$$nick]}};
	for my $chan (@{$chans[$$nick]}) {
		unless ($chan->is_on($home)) {
			Log::err("Found nick $$nick on delinked channel $$chan");
			$chans[$$nick] = [ grep { $_ ne $chan } @{$chans[$$nick]} ];
			next;
		}
		for my $net ($chan->nets()) {
			delete $leave{$$net};
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

=item $nick->str($net)

Get the nick's name on the given network

=cut

sub str {
	my($nick,$net) = @_;
	$nicks[$$nick]{$$net};
}

our @ts;
sub ts {
	my($nick,$net) = @_;
	$nickts[$$nick]{$$net} ||= $ts[$$nick] if exists $ts[$$nick];
	$nickts[$$nick]{$$net};
}

=back

=cut

Event::hook_add(
	NEWNICK => act => sub {
		my $act = shift;
		my $nick = $act->{dst};
		$Janus::gnicks{$nick->gid} = $nick;
	}, CONNECT => check => sub {
		my $act = shift;
		my $nick = $act->{dst};
		my $net = $act->{net};
		return 1 if exists $nets[$$nick]{$$net};
		undef;
	}, CONNECT => act => sub {
		my $act = shift;
		my $nick = $act->{dst};
		my $net = $act->{net};
		$nets[$$nick]{$$net} = $net;
		return if $net->jlink();

		my $rnick = $net->request_newnick($nick, $homenick[$$nick], $act->{tag});
		$nickts[$$nick]->{$$net} = $Janus::time;
		$nicks[$$nick]->{$$net} = $rnick;
	}, RECONNECT => act => sub {
		my $act = shift;
		my $nick = $act->{dst};
		my $net = $act->{net};

		delete $act->{except};

		if ($act->{altnick}) {
			my $from = $act->{from} = $nicks[$$nick]{$$net};
			my $to = $act->{to} = $net->request_cnick($nick, $homenick[$$nick], 2);
			$nickts[$$nick]->{$$net} = $Janus::time;
			$nicks[$$nick]{$$net} = $to;
		}

		if ($act->{killed}) {
			$act->{reconnect_chans} = [ @{$chans[$$nick]} ];
		}
	}, NICK => act => sub {
		my $act = $_[0];
		my $nick = $act->{dst};
		my $old = $homenick[$$nick];
		my $new = $act->{nick};
		my $ftag = $act->{tag} || {};

		for my $id (keys %{$nets[$$nick]}) {
			my $net = $nets[$$nick]->{$id};
			next if $net->jlink();
			my $tag = $ftag->{$id};
			my $from = $nicks[$$nick]->{$id};
			my $to = $net->request_cnick($nick, $new, $tag);
			$nicks[$$nick]->{$id} = $to;
			$nickts[$$nick]->{$$net} = ($net == $nick->homenet && $act->{nickts}) || $Janus::time;

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
		my $i = $act->{item};
		$act->{value} =~ s/(?:\003\d{0,2}(?:,\d{1,2})?|[\001\002\004-\037])//g
			if $i eq 'host' || $i eq 'vhost' || $i eq 'ident';
		$info[$$nick]{$i} = $act->{value};
	}, UMODE => act => sub {
		my $act = $_[0];
		my $nick = $act->{dst};
		for my $ltxt (@{$act->{mode}}) {
			if ($ltxt =~ /\+(.*)/) {
				$mode[$$nick] |= $umodebit{$1};
			} elsif ($ltxt =~ /-(.*)/) {
				$mode[$$nick] &= ~$umodebit{$1};
			} else {
				warn "Bad umode change $ltxt";
			}
		}
	}, QUIT => cleanup => sub {
		my $act = $_[0];
		my $nick = $act->{dst};
		my @clist = @{$chans[$$nick]};
		for my $chan (@clist) {
			$chan->part($nick);
		}
		for my $id (keys %{$nets[$$nick]}) {
			my $net = $nets[$$nick]->{$id};
			next if $net->jlink();
			my $name = $nicks[$$nick]->{$id};
			$net->release_nick($name, $nick);
		}
		delete $chans[$$nick];
		delete $nets[$$nick];
		delete $homenet[$$nick];
		delete $Janus::gnicks{$nick->gid()};
		Persist::poison($nick);
	}, JOIN => act => sub {
		my $act = shift;
		my $nick = $act->{src};
		my $chan = $act->{dst};

		$nick->rejoin($chan)
	}, PART => cleanup => sub {
		my $act = $_[0];
		my $nick = $act->{src};
		my $chan = $act->{dst};

		$chans[$$nick] = [ grep { $_ ne $chan } @{$chans[$$nick]} ];
		$nick->_netclean($chan->nets());
	}, KICK => cleanup => sub {
		my $act = $_[0];
		my $nick = $act->{kickee};
		my $chan = $act->{dst};

		$chans[$$nick] = [ grep { $_ ne $chan } @{$chans[$$nick]} ];
		$nick->_netclean($chan->nets());
	}, NETSPLIT => act => sub {
		my $act = shift;
		my $net = $act->{net};
		my $msg = 'hub.janus '.$net->jname();
		my @nicks = $net->all_nicks();
		my @clean;
		for my $n (@nicks) {
			if ($n->homenet() eq $net) {
				push @clean, {
					type => 'QUIT',
					dst => $n,
					msg => $msg,
					except => $net,
					netsplit_quit => 1,
					nojlink => 1,
				};
			} else {
				$n->_netpart($net);
			}
		}
		Event::insert_full(@clean); @clean = ();

		Log::debug("Nick deallocation start");
		for (0..$#nicks) {
			weaken($nicks[$_]);
			my $n = $nicks[$_] or next;
			next if 'Persist::Poison' eq ref $n;
			next unless $n->homenet() eq $net;
			Persist::poison($nicks[$_]);
		}
		@nicks = ();
		Log::debug("Nick deallocation end");
	}, KILL => act => sub {
		# TODO this is very specific to Link-mode kills
		my $act = shift;
		my $nick = $act->{dst};
		my $net = $act->{net};
		if ($nick->is_on($net) && !$net->jlink() && (!$act->{except} || $act->{except} ne $net)) {
			$net->send({
				type => 'QUIT',
				dst => $nick,
				msg => $act->{msg},
				killer => $act->{src},
			});
		}
		for my $chan (@{$chans[$$nick]}) {
			next unless $chan->is_on($net);
			my $act = {
				type => 'KICK',
				src => ($act->{src} || $net),
				dst => $chan,
				kickee => $nick,
				msg => $act->{msg},
				except => $net,
				nojlink => 1,
			};
			Event::append($act);
		}
	}, KILL => cleanup => sub {
		my $act = shift;
		my $nick = $act->{dst};
		my $net = $act->{net};
		$nick->_netpart($net);
	},
);

1;
