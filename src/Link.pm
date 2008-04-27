# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Link;
use strict;
use warnings;
use integer;
use Debug;
use Lock;

if ($Janus::lmode) {
	die "Wrong link mode" unless $Janus::lmode eq 'Link';
} else {
	$Janus::lmode = 'Link';
}

our %reqs;
# {requestor}{destination}{src-channel} = {
#  src => src-channel [? if ever useful]
#  dst => dst-channel
#  mask => nick!ident@host of requestor
#  time => unix timestamp of request

# Emergency shutoff switch for retries
our $abort;

&Janus::save_vars('reqs', \%reqs);

&Janus::hook_add(
	NETLINK => act => sub {
		my $act = shift;
		my $net = $act->{net};
		return unless $net->jlink();
		# clear the request list as it will be repopulated as part of the remote sync
		delete $reqs{$net->name()};
	}, LINKED => act => sub {
		my $act = shift;
		my $net = $act->{net};
		return if $net->jlink();
		my $bynet = $reqs{$net->name()} or return;
		my @acts;
		for my $nname (sort keys %$bynet) {
			my $bychan = $bynet->{$nname} or next;
			my $dnet = $Janus::nets{$nname} or next;
			for my $src (sort keys %$bychan) {
				my $ifo = $bychan->{$src};
				$ifo = { dst => $ifo } unless ref $ifo;
				push @acts, +{
					type => 'LINKREQ',
					net => $net,
					dst => $dnet,
					slink => $src,
					dlink => $ifo->{dst},
					reqby => $ifo->{nick},
					reqtime => $ifo->{time},
					linkfile => 1,
				};
			}
		}
		&Janus::append(@acts);
	}, JLINKED => act => sub {
		my $act = shift;
		my $ij = $act->{except};
		my @nets = grep { $_->jlink() && $_->jlink() eq $ij } values %Janus::nets;
		my @acts;
		for my $lto (@nets) {
			for my $net (values %Janus::nets) {
				next if $ij->jparent($net->jlink());
				my $bychan = $reqs{$net->name()}{$lto->name()};
				for my $src (sort keys %$bychan) {
					my $ifo = $bychan->{$src};
					$ifo = { dst => $ifo } unless ref $ifo;
					push @acts, +{
						type => 'LINKREQ',
						net => $net,
						dst => $lto,
						slink => $src,
						dlink => $ifo->{dst},
						reqby => $ifo->{nick},
						reqtime => $ifo->{time},
						linkfile => $ij->is_linked(),
					};
				}
			}
		}
		&Janus::append(@acts);
	}, LINKREQ => act => sub {
		my $act = shift;
		my $snet = $act->{net};
		my $dnet = $act->{dst};
		# don't let people request reflexive links
		return if $snet eq $dnet;
		$reqs{$snet->name()}{$dnet->name()}{lc $act->{slink}} = {
			dst => $act->{dlink},
			nick => $act->{reqby},
			'time' => $act->{reqtime},
		};
		if ($dnet->jlink() || $dnet->isa('Interface')) {
			&Debug::info("Link request: dst non-local");
			return;
		}
		unless ($dnet->is_synced()) {
			&Debug::info("Link request: dst not ready");
			return;
		}
		my $recip = $reqs{$dnet->name()}{$snet->name()}{lc $act->{dlink}};
		$recip = $recip->{dst} if ref $recip;
		unless ($recip) {
			&Debug::info("Link request: saved in list");
			return;
		}
		if ($act->{linkfile} && $act->{linkfile} == 2) {
			&Debug::info("Link request: not syncing to avoid races");
			return;
		}
		my $kn1 = $snet->gid().lc $act->{slink};
		my $kn2 = $dnet->gid().lc $act->{dlink};
		if ($Janus::gchans{$kn1} && $Janus::gchans{$kn2} &&
			$Janus::gchans{$kn1} eq $Janus::gchans{$kn2}) {
			&Debug::info("Link request: already linked");
			return;
		}
		if ($act->{override} || $recip eq 'any' || lc $recip eq lc $act->{slink}) {
			&Debug::info("Link request: linking $kn1 and $kn2");
			&Lock::req_pair($act, $snet, $dnet);
		} else {
			&Debug::info("Link request: name mismatch");
		}
	}, DELINK => act => sub {
		my $act = shift;
		my $src = $act->{src};
		my $chan = $act->{dst};
		return unless $src && $src->isa('Nick');
		my $snet = $src->homenet();

		my $sname = $snet->name();
		my $scname = lc($chan->str($snet) || $act->{split}->str($snet));
		if ($snet eq $act->{net}) {
			# delink own network: delete all outgoing requests
			for my $net ($chan->nets()) {
				next if $net eq $snet;
				delete $reqs{$sname}{$net->name()}{$scname};
			}
		} else {
			# delink other network: delete only that request
			delete $reqs{$sname}{$act->{net}->name()}{$scname};
		}
	}, REQDEL => act => sub {
		my $act = shift;
		my $src = $act->{snet};
		my $dst = $act->{dnet};
		if (delete $reqs{$src->name()}{$dst->name()}{lc $act->{name}}) {
			&Janus::jmsg($act->{src}, 'Deleted');
		} else {
			&Janus::jmsg($act->{src}, 'Not found');
		}
	},
);

1;
