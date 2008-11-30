# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Link;
use strict;
use warnings;
use integer;

if ($Janus::lmode) {
	die "Wrong link mode" unless $Janus::lmode eq 'Link';
} else {
	$Janus::lmode = 'Link';
}

our %request;
# {network}{channel} = {
#  mask => nick!ident@host of requestor
#  time => unix timestamp of request
#  mode 0: link TO
#   net  => master network
#   chan => master channel
#  mode 1: allow default
#   ack{net} => =2 denies
#  mode 2: deny default
#   ack{net} => =1 allows

our %def_ack;
# {network} = default contents of the "ack" entry

&Janus::save_vars(
	request => \%request,
	def_ack => \%def_ack,
);

sub link_to_janus {
	my $chan = shift;
	return if $chan->is_on($Interface::network);
	my $ifchan = Channel->new(
		net => $Interface::network,
		name => $chan->real_keyname,
		ts => $chan->ts,
	);
	Event::append({
		type => 'CHANLINK',
		dst => $chan,
		in => $ifchan,
		net => $Interface::network,
		name => $chan->real_keyname,
		nojlink => 1,
	});
}

sub autolink_from {
	my($net,$mask) = @_;
	my @acts;
	my $netn = $net->name();
	my $bychan = $request{$netn} or return;
	for my $src (sort keys %$bychan) {
		my $ifo = $bychan->{$src} or next;
		my $chan = $net->chan($src, 1);
		if ($ifo->{mode}) {
			link_to_janus($chan);
			next;
		}
		my $dst = $Janus::nets{$ifo->{net}} or next;
		if ($mask && !$mask->jparent($dst)) {
			next;
		}
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
	&Event::append(@acts);
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
			next if $ifo->{mode};
			next unless $ifo->{net} && $netok{$ifo->{net}};
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
	&Event::append(@acts);
}

sub send_avail {
	my $ij = shift;
	my @acts;
	for my $sname (sort keys %request) {
		my $snet = $Janus::nets{$sname} or next;
		next if $ij->jparent($snet);
		for my $cname (sort keys %{$request{$sname}}) {
			my $ifo = $request{$sname}{$cname};
			next unless $ifo->{mode};
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

&Event::hook_add(
	NETLINK => act => sub {
		my $act = shift;
		my $net = $act->{net};
		return unless $net->jlink();
		# clear the request list as it will be repopulated as part of the remote sync
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
		my $src = $act->{src};
		my $schan = $act->{chan};
		my $snet = $schan->homenet();
		my $snetn = $snet->name;
		my $sname = $schan->str($snet);
		my $dnet = $act->{dst};
		my $dnetn = $dnet->name;
		my $dname = $act->{dlink};
		my $logpfx = "Link request $snetn$sname -> $dnetn$dname:";
		if ($request{$snetn}{lc $sname}{mode}) {
			Log::info($logpfx, 'not overriding locally created');
			Janus::jmsg($src, "$sname is shared by this network, and must be linked from others") if $src;
			return;
		}
		$request{$snetn}{lc $sname} = {
			net => $dnetn,
			chan => $dname,
			mask => $act->{reqby},
			'time' => $act->{reqtime},
		};
		if ($dnet->jlink() || $dnet->isa('Interface')) {
			Log::info($logpfx, 'dst non-local, routing');
			return;
		}
		unless ($dnet->is_synced()) {
			Log::info($logpfx, 'dst not ready, waiting');
			return;
		}
		my $recip = $request{$dnet->name()}{lc $act->{dlink}};
		unless ($recip && $recip->{mode}) {
			Log::info($logpfx, 'destination not shared');
			Janus::jmsg($src, "The channel $dname has not been shared by $dnetn") if $src;
			return;
		}
		if ($recip->{ack}{$snetn}) {
			if ($recip->{ack}{$snetn} == 2) {
				Log::info($logpfx, 'rejected explicitly by homenet');
				Janus::jmsg($src, "The request to link $dname on $dnetn has been denied") if $src;
				return;
			}
		} elsif ($recip->{mode} == 2) {
			Log::info($logpfx, 'rejected by default ACL');
			Janus::jmsg($src, "The request to link $dname on $dnetn has been denied") if $src;
			return;
		}
		if (1 < scalar $schan->nets()) {
			Log::info($logpfx, 'source already linked');
			return;
		}
		unless ($dnet->jlink()) {
			my $dchan = $dnet->chan($act->{dlink}, 1);
			if ($dchan->is_on($snet)) {
				Log::info($logpfx, 'destination already on requested network');
				return;
			}
			&Event::append({
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
		my $name = lc $act->{name};
		my %req = (
			mode => 1,
			mask => $act->{reqby},
			'time', $act->{reqtime},
		);
		$req{ack} = { %{$def_ack{$net->name}} } if $def_ack{$net->name};
		if ($act->{remove}) {
			delete $request{$net->name}{$name};
			return if $net->jlink;
		} else {
			$request{$net->name}{$name} = \%req;
			return if $net->jlink;
			my $chan = $net->chan($name, 1);
			link_to_janus($chan);
		}
	}, DELINK => act => sub {
		my $act = shift;
		my $net = $act->{net};
		my $nname = $net->name();
		my $chan = $act->{dst};
		my $cname = $chan->str($net);
		my $hnet = $chan->homenet();
		my $cause = $act->{cause};
		if ($cause eq 'destroy') {
			delete $request{$nname}{$cname};
		} elsif ($cause eq 'reject') {
			$request{$hnet->name}{lc $chan->homename}{ack}{$nname} = 2;
		} elsif ($cause eq 'unlink') {
			# standard delink
			delete $request{$nname}{$cname};
		} elsif ($cause !~ /split2?|destroy2/) {
			&Log::warn("Unknown cause in DELINK: $cause");
		}
	},
);

&Event::setting_add({
	name => 'oper_only_link',
	type => 'LocalNetwork',
	acl_local_w => 'set/network',
	acl_w => 'setall/network',
});

1;
