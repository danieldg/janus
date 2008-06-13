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
		my $chan = $net->chan($src, 1);
		push @acts, +{
			type => 'LINKREQ',
			chan => $chan,
			dst => $dst,
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
		for my $cname (sort keys %{$request{$src}}) {
			my $ifo = $request{$src}{$cname};
			next unless $netok{$ifo->{net}};
			my $net = $Janus::nets{$ifo->{net}} or next;
			my $chan = $snet->chan($cname, 1);
			push @acts, +{
				type => 'LINKREQ',
				chan => $chan,
				dst => $net,
				dlink => $ifo->{chan},
				reqby => $ifo->{mask},
				reqtime => $ifo->{time},
				linkfile => 1,
			};
		}
	}
	&Janus::append(@acts);
}

sub send_avail {
	my $ij = shift;
	my @acts;
	for my $sname (sort keys %avail) {
		my $snet = $Janus::nets{$sname} or next;
		next if $ij->jparent($snet);
		for my $cname (sort keys %{$avail{$sname}}) {
			my $ifo = $avail{$sname}{$cname};
			push @acts, +{
				type => 'LINKOFFER',
				src => $snet,
				name => $cname,
				reqby => $ifo->{mask},
				reqtime => $ifo->{time},
			};
		}
	}
	$ij->send(@acts);
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
		# Linking channels to a network is done at the remote-generated LINKED event
		# my @nets = grep { $ij->jparent($_) } values %Janus::nets;
		# autolink_to(@nets);
		send_avail($ij);
	}, LINKREQ => act => sub {
		my $act = shift;
		my $schan = $act->{chan};
		my $snet = $schan->homenet();
		my $sname = $schan->str($snet);
		my $dnet = $act->{dst};
		$request{$snet->name()}{lc $sname} = {
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
		if (1 < scalar $schan->nets()) {
			&Debug::info("Link request: already linked");
			return;
		}
		unless ($dnet->jlink()) {
			my $dchan = $dnet->chan($act->{dlink}, 1);
			&Janus::append({
				type => 'CHANLINK',
				dst => $dchan,
				in => $schan,
				net => $snet,
				name => $sname,
			});
		}
	}, LINKOFFER => act => sub {
		my $act = shift;
		my $net = $act->{src};
		$avail{$net->name()}{$act->{name}} = {
			mode => 1,
			mask => $act->{reqby},
			'time', $act->{reqtime},
		};
		# wait to link until someone requests
	}, DELINK => act => sub {
		my $act = shift;
		# do not process derived actions
		return if $act->{nojlink};
		my $net = $act->{net};
		my $nname = $net->name();
		my $chan = $act->{dst};
		my $cname = $chan->str($net);
		if ($chan->homenet() == $net) {
			delete $avail{$nname}{$cname};
		} else {
			# TODO set unavailable if rejected
			delete $request{$nname}{$cname};
		}
	},
);

1;
