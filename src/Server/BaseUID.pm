# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Server::BaseUID;
use Debug;
use LocalNetwork;
use Persist 'LocalNetwork';
use strict;
use warnings;
use integer;

our(@nick2uid, @uids, @gid2uid);
&Persist::register_vars(qw(nick2uid uids gid2uid));

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
		&Debug::warn_in($net, "Nick used where UID expected; converting");
		$name = $nick2uid[$$net]{lc $name} || $name;
	}
	my $nick = $uids[$$net]{uc $name};
	unless ($nick) {
		&Debug::warn_in($net, "UID '$name' does not exist; ignoring");
		return undef;
	}
	if ($nick->homenet() ne $net) {
		&Debug::err_in($net, "UID '$name' is from network '".$nick->homenet()->name().
			"' but was sourced locally");
		return undef;
	}
	return $nick;
}

sub nick {
	my($net, $name) = @_;
	if ($name !~ /^\d/) {
		&Debug::warn_in($net, "Nick used where UID expected: converting") unless $_[2];
		$name = $nick2uid[$$net]{lc $name} || $name;
	}
	return $uids[$$net]{uc $name} if $uids[$$net]{uc $name};
	&Debug::warn_in($net, "UID '$name' does not exist; ignoring") unless $_[2];
	undef;
}

# use for LOCAL nicks only
sub register_nick {
	my($net, $new, $new_uid) = @_;
	$uids[$$net]{uc $new_uid} = $new;
	$gid2uid[$$net]{$new->gid()} = $new_uid;
	&Debug::info("Registering $new_uid for nick #$$new");
	my $name = $new->str($net);
	my $old_uid = delete $nick2uid[$$net]{lc $name};
	unless ($old_uid) {
		$nick2uid[$$net]{lc $name} = $new_uid;
		return ();
	}

	# TODO is this collision code too inspircd-specific? It may need to be moved
	my $old = $uids[$$net]{uc $old_uid} or warn;
	my $tsctl = $old->ts() <=> $new->ts();

	if ($new->info('ident') eq $old->info('ident') && $new->info('host') eq $old->info('host')) {
		# this is a ghosting nick, we REVERSE the normal timestamping
		$tsctl = -$tsctl;
	}

	my @rv;
	if ($tsctl >= 0) {
		$nick2uid[$$net]{lc $name} = $new_uid;
		$nick2uid[$$net]{lc $old_uid} = $old_uid;
		if ($old->homenet() eq $net) {
			push @rv, +{
				type => 'NICK',
				dst => $old,
				nick => $old_uid,
				nickts => 1, # this is a UID-based nick, it ALWAYS wins.
			}
		} else {
			push @rv, +{
				type => 'RECONNECT',
				dst => $old,
				killed => 0,
			};
		}
	}
	if ($tsctl <= 0) {
		$nick2uid[$$net]{lc $new_uid} = $new_uid;
		$nick2uid[$$net]{lc $name} = $old_uid;
		push @rv, +{
			type => 'NICK',
			dst => $new,
			nick => $new_uid,
			nickts => 1,
		};
	}
	delete $nick2uid[$$net]{lc $name} if $tsctl == 0;
	@rv;
}

sub _request_nick {
	my($net, $nick, $reqnick, $tagged) = @_;
	$reqnick =~ s/[^0-9a-zA-Z\[\]\\^\-_`{|}]/_/g;
	my $maxlen = $net->nicklen();
	my $given = substr $reqnick, 0, $maxlen;

	$tagged = 1 if exists $nick2uid[$$net]->{lc $given};

	my $tagre = $net->param('force_tag');
	$tagged = 1 if $tagre && $given =~ /$tagre/;

	if ($tagged) {
		my $tagsep = $net->param('tag_prefix');
		$tagsep = '/' unless defined $tagsep;
		my $tag = $tagsep . $nick->homenet()->name();
		my $i = 0;
		$given = substr($reqnick, 0, $maxlen - length $tag) . $tag;
		while (exists $nick2uid[$$net]->{lc $given}) {
			my $itag = $tagsep.(++$i).$tag; # it will find a free nick eventually...
			$given = substr($reqnick, 0, $maxlen - length $itag) . $itag;
		}
	}
	$given;
}

# Request a nick on a remote network (CONNECT/JOIN must be sent AFTER this)
sub request_newnick {
	my($net, $nick, $reqnick, $tagged) = @_;
	my $given = _request_nick(@_);
	my $uid = $net->next_uid($nick->homenet());
	&Debug::info("Registering nick #$$nick as uid $uid with nick $given");
	$uids[$$net]{uc $uid} = $nick;
	$nick2uid[$$net]{lc $given} = $uid;
	$gid2uid[$$net]{$nick->gid()} = $uid;
	return $given;
}

sub request_cnick {
	my($net, $nick, $reqnick, $tagged) = @_;
	my $given = _request_nick(@_);
	my $current = $nick->str($net);
	$nick2uid[$$net]{lc $given} = delete $nick2uid[$$net]{lc $current};
	$given;
}

# Release a nick on a remote network (PART/QUIT must be sent BEFORE this)
sub release_nick {
	my($net, $req, $nick) = @_;
	delete $nick2uid[$$net]{lc $req};
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

1;
