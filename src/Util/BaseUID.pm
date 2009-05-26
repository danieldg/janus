# Copyright (C) 2007-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Util::BaseUID;
use LocalNetwork;
use Persist 'LocalNetwork';
use strict;
use warnings;
use integer;

our(@nick2uid, @uids, @gid2uid);
Persist::register_vars(qw(nick2uid uids gid2uid));

sub _init {
	my $net = shift;
	$uids[$$net] = {};
	$nick2uid[$$net] = {};
}

sub nick2uid {
	my($net, $nick) = @_;
	$gid2uid[$$net]{$nick->gid()};
}

sub mynick {
	my($net, $name) = @_;
	if ($name !~ /^\d/) {
		Log::warn_in($net, "Nick used where UID expected; converting");
		$name = $net->lc($name);
		$name = $nick2uid[$$net]{$name} || $name;
	}
	my $nick = $uids[$$net]{uc $name};
	unless ($nick) {
		Log::warn_in($net, "UID '$name' does not exist; ignoring");
		return undef;
	}
	if ($nick->homenet() ne $net) {
		Log::err_in($net, "UID '$name' is from network '".$nick->homenet()->name().
			"' but was sourced locally");
		return undef;
	}
	return $nick;
}

sub nick {
	my($net, $name) = @_;
	if ($name !~ /^\d/) {
		Log::warn_in($net, "Nick used where UID expected: converting") unless $_[2];
		$name = $net->lc($name);
		$name = $nick2uid[$$net]{$name} || $name;
	}
	return $uids[$$net]{uc $name} if $uids[$$net]{uc $name};
	Log::warn_in($net, "UID '$name' does not exist; ignoring") unless $_[2];
	undef;
}

# use for LOCAL nicks only
sub register_nick {
	my($net, $new, $new_uid) = @_;
	$uids[$$net]{uc $new_uid} = $new;
	$gid2uid[$$net]{$new->gid()} = $new_uid;
	my $name = $new->str($net);
	Log::debug_in($net, "Registering $new_uid for local nick $name #$$new");

	my @rv = +{
		type => 'NEWNICK',
		dst => $new,
	};

	$name = $net->lc($name);
	my $old_uid = delete $nick2uid[$$net]{$name};
	unless ($old_uid) {
		$nick2uid[$$net]{$name} = $new_uid;
		return @rv;
	}
	my $old = $uids[$$net]{uc $old_uid} or warn;

	if ($old->homenet == $net) {
		# collide of two nicks on the network. Let the protocol module figure out who won
		my $tsctl = $net->collide_winner($old,$new);

		Log::debug("Nick self-collision over $name, old=".$old->ts($net)." new=".$new->ts($net)." tsctl=$tsctl");

		$nick2uid[$$net]{$name} = $new_uid if $tsctl > 0;
		$nick2uid[$$net]{$name} = $old_uid if $tsctl < 0;
		if ($tsctl >= 0) {
			unshift @rv, +{
				type => 'NICK',
				dst => $old,
				nick => $old_uid,
				nickts => 1, # this is a UID-based nick, it ALWAYS wins.
			};
		}
		if ($tsctl <= 0) {
			push @rv, +{
				type => 'NICK',
				dst => $new,
				nick => $new_uid,
				nickts => 1,
			};
		}
	} else {
		# Old user of the nick was a janus nick. Give it up by reconnecting
		$nick2uid[$$net]{$name} = $new_uid;
		unshift @rv, +{
			type => 'RECONNECT',
			net => $net,
			dst => $old,
			killed => 0,
			altnick => 1,
		};
	}
	@rv;
}

sub _request_nick {
	my($net, $nick, $reqnick, $tagged) = @_;
	$reqnick =~ s/[^0-9a-zA-Z\[\]\\^\-_`{|}]/_/g;
	my $maxlen = $net->nicklen();
	my $given = substr $reqnick, 0, $maxlen;
	my $given_lc = $net->lc($given);

	$tagged = 1 if exists $nick2uid[$$net]->{$given_lc};

	my $tagre = Setting::get(force_tag => $net);
	$tagged = 1 if $tagre && $$nick != 1 && $given =~ /$tagre/;

	if ($tagged) {
		my $tagsep = Setting::get(tagsep => $net);
		my $tag = $tagsep . $nick->homenet()->name();
		my $i = 0;
		$given = substr($reqnick, 0, $maxlen - length $tag) . $tag;
		$given_lc = $net->lc($given);
		while (exists $nick2uid[$$net]->{$given_lc}) {
			my $itag = $tagsep.(++$i).$tag; # it will find a free nick eventually...
			$given = substr($reqnick, 0, $maxlen - length $itag) . $itag;
			$given_lc = $net->lc($given);
		}
	}
	($given,$given_lc);
}

# Request a nick on a remote network (CONNECT/JOIN must be sent AFTER this)
sub request_newnick {
	my($net, $nick, $reqnick, $tagged) = @_;
	my($given,$glc) = _request_nick(@_);
	my $uid = $net->next_uid($nick->homenet());
	Log::debug_in($net, "Registering nick #$$nick as uid $uid with nick $given");
	$uids[$$net]{uc $uid} = $nick;
	$nick2uid[$$net]{$glc} = $uid;
	$gid2uid[$$net]{$nick->gid()} = $uid;
	return $given;
}

sub request_cnick {
	my($net, $nick, $reqnick, $tagged) = @_;
	$tagged ||= 0;
	my $uid = $net->nick2uid($nick);
	my $current = $net->lc($nick->str($net));
	my $curr_uid = $nick2uid[$$net]{$current} || '';
	if ($tagged != 2 && $curr_uid eq $uid) {
		delete $nick2uid[$$net]{$current};
	}
	my($given,$glc) = _request_nick(@_);
	if ($tagged == 2 && $curr_uid eq $uid) {
		delete $nick2uid[$$net]{$current};
	}
	$nick2uid[$$net]{$glc} = $uid;
	$given;
}

# Release a nick on a remote network (PART/QUIT must be sent BEFORE this)
sub release_nick {
	my($net, $req, $nick) = @_;
	$req = $net->lc($req);
	delete $nick2uid[$$net]{$req};
	my $uid = delete $gid2uid[$$net]{$nick->gid()};
	delete $uids[$$net]{uc $uid};
}

sub all_nicks {
	my $net = shift;
	values %{$uids[$$net]};
}

sub item {
	my($net, $item) = @_;
	return undef unless defined $item;
	return $net->chan($item) if $item =~ /^#/;
	return $uids[$$net]{uc $item} if exists $uids[$$net]{uc $item};
	return $net if $item =~ /\./ || $item =~ /^[0-9]..$/;
	return undef;
}

sub _out {
	my($net,$itm) = @_;
	return '' unless defined $itm;
	return $itm =~ / |^:|^$/ ? ':'.$itm : $itm unless ref $itm;
	if ($itm->isa('Nick')) {
		my $rv;
		$rv = $net->nick2uid($itm) if $itm->is_on($net);
		$rv = $net->net2uid($itm->homenet()) unless defined $rv;
		return $rv;
	} elsif ($itm->isa('Channel')) {
		return $itm->str($net);
	} elsif ($itm->isa('Network') || $itm->isa('RemoteJanus')) {
		return $net->net2uid($itm);
	} else {
		Log::err_in($net, "Unknown item $itm");
		return $net->net2uid($net);
	}
}

Event::hook_add(
	INFO => 'Nick:1' => sub {
		my($dst, $nick) = @_;
		my $out;
		for my $net ($nick->netlist) {
			next unless $net->isa(__PACKAGE__);
			$out .= ' @'.$net->name.'='.$net->nick2uid($nick);
		}
		return unless $out;
		Janus::jmsg($dst, "\002Protocol UIDs\002:".$out);
	},
);

1;
