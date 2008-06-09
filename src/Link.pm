# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Link;
use strict;
use warnings;
use integer;
use Debug;

if ($Janus::lmode) {
	die "Wrong link mode" unless $Janus::lmode eq 'Link';
} else {
	$Janus::lmode = 'Link';
}

our %avail;
# {network}{channel} = {
#? mode => 1=allow by default, 2=deny by default (ask)
#? ack{net} => 0/undef=default, 1=allow, 2=deny
#  mask => nick!ident@host of requestor
#  time => unix timestamp of request

our %request;
# {network}{channel} = {
#  net  => master network
#  chan => master channel
#  mask => nick!ident@host of requestor
#  time => unix timestamp of request

&Janus::save_vars(
	avail => \%avail,
	request => \%request,
);

sub autolink_from {
	my($net,$mask) = @_;
	my @acts;
	my $netn = $net->name();
	my $bychan = $request{$netn} or return;
	for my $src (sort keys %$bychan) {
		my $ifo = $bychan->{$src} or next;
		my $dst = $Janus::nets{$ifo->{net}} or next;
		if ($mask && !$mask->jparent($dst)) {
			next;
		}
		push @acts, +{
			type => 'LINKREQ',
			net => $net,
			dst => $dst,
			slink => $src,
			dlink => $ifo->{chan},
			reqby => $ifo->{mask},
			reqtime => $ifo->{time},
			linkfile => 1,
		};
	}
	&Janus::append(@acts);
}

sub autolink_to {
	my %netok;
	my @acts;
	$netok{$_->name()} = 1 for @_;
	for my $src (sort keys %request) {
		my $snet = $Janus::nets{$src} or next;
		next if $snet->jlink();
		for my $chan (sort keys %{$request{$src}}) {
			my $ifo = $request{$src}{$chan};
			next unless $netok{$ifo->{net}};
			my $net = $Janus::nets{$ifo->{net}} or next;
			push @acts, +{
				type => 'LINKREQ',
				net => $src,
				dst => $net,
				slink => $chan,
				dlink => $ifo->{chan},
				reqby => $ifo->{mask},
				reqtime => $ifo->{time},
				linkfile => 1,
			};
		}
	}
	&Janus::append(@acts);
}

&Janus::hook_add(
	NETLINK => act => sub {
		my $act = shift;
		my $net = $act->{net};
		return unless $net->jlink();
		# clear the request list as it will be repopulated as part of the remote sync
		delete $avail{$net->name()};
		delete $request{$net->name()};
	}, LINKED => act => sub {
		my $act = shift;
		my $net = $act->{net};
		autolink_from($net) unless $net->jlink();
		autolink_to($net);
	}, JLINKED => act => sub {
		my $act = shift;
		my $ij = $act->{except};
		my @nets = grep { $ij->jparent($_) } values %Janus::nets;
		autolink_to(@nets);
	}, LINKREQ => act => sub {
		my $act = shift;
		my $snet = $act->{net};
		my $dnet = $act->{dst};
		return if $snet eq $dnet;
		$request{$snet->name()}{lc $act->{slink}} = {
			net => $dnet->name(),
			chan => $act->{dlink},
			mask => $act->{reqby},
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
		my $recip = $avail{$dnet->name()}{lc $act->{dlink}};
		unless ($recip) {
			&Debug::info("Link request: saved in list");
			return;
		}
		# TODO check for true availability
		my $kn1 = $snet->gid().lc $act->{slink};
		if ($Janus::gchans{$kn1}) {
			my $sc = $Janus::gchans{$kn1};
			if (1 < scalar $sc->nets()) {
				&Debug::info("Link request: already linked");
				return;
			}
		}
		unless ($dnet->jlink()) {
			my $chan = $dnet->chan($act->{dlink}, 1);
			&Janus::append({
				type => 'CHANLINK',
				chan => $chan,
				net => $snet,
				name => $act->{slink},
			});
		}
	}, DELINK => act => sub {
		# TODO remove requests and such
	},
);

1;
