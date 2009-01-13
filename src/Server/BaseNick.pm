# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Server::BaseNick;
use LocalNetwork;
use Persist 'LocalNetwork';
use Scalar::Util qw(isweak weaken);
use strict;
use warnings;

our @nicks;
&Persist::register_vars('nicks');

sub _init {
	my $net = shift;
	$nicks[$$net] = {};
}

sub mynick {
	my($net, $name) = @_;
	my $nick = $nicks[$$net]{lc $name};
	unless ($nick) {
		&Log::debug_in($net, "Nick '$name' does not exist; ignoring");
		return undef;
	}
	if ($nick->homenet() ne $net) {
		&Log::err_in($net, "Nick '$name' is from network '".$nick->homenet()->name().
			"' but was sourced locally");
		return undef;
	}
	return $nick;
}

sub nick {
	my($net, $name) = @_;
	return $nicks[$$net]{lc $name} if $nicks[$$net]{lc $name};
	&Log::debug_in($net, "Nick '$name' does not exist; ignoring") unless $_[2];
	undef;
}

sub nick_collide {
	my($net, $name, $new) = @_;
	my $old = delete $nicks[$$net]->{lc $name};
	unless ($old) {
		$nicks[$$net]->{lc $name} = $new;
		return 1;
	}
	my $tsctl = $old->ts() <=> $new->ts();

	&Log::debug("Nick collision over $name, old=".$old->ts." new=".$new->ts." tsctl=$tsctl");

	$nicks[$$net]->{lc $name} = $new if $tsctl > 0;
	$nicks[$$net]->{lc $name} = $old if $tsctl < 0;

	my @rv = ($tsctl > 0);
	if ($tsctl >= 0) {
		# old nick lost, reconnect it
		if ($old->homenet() eq $net) {
			&Log::err_in($net, "Nick collision on home network!");
		} else {
			push @rv, +{
				type => 'RECONNECT',
				dst => $old,
				net => $net,
				killed => 1,
				altnick => 1,
			};
		}
	}
	@rv;
}

# Request a nick on a remote network (CONNECT/JOIN must be sent AFTER this)
sub request_nick {
	my($net, $nick, $reqnick, $tagged) = @_;
	my $given;
	if ($nick->homenet() eq $net) {
		$given = $reqnick;
	} else {
		$reqnick =~ s/[^0-9a-zA-Z\[\]\\^\-_`{|}]/_/g;
		$reqnick = '_'.$reqnick unless $reqnick =~ /^[A-Za-z\[\]\\^\-_`{|}]/;
		my $maxlen = $net->nicklen();
		$given = substr $reqnick, 0, $maxlen;

		$tagged = 1 if exists $nicks[$$net]->{lc $given};

		my $tagre = Setting::get(force_tag => $net);
		$tagged = 1 if $tagre && $$nick != 1 && $given =~ /^$tagre$/;

		if ($tagged) {
			my $tagsep = Setting::get(tagsep => $net);
			my $tag = $tagsep . $nick->homenet()->name();
			my $i = 0;
			$given = substr($reqnick, 0, $maxlen - length $tag) . $tag;
			while (exists $nicks[$$net]->{lc $given}) {
				my $itag = $tagsep.(++$i).$tag; # it will find a free nick eventually...
				$given = substr($reqnick, 0, $maxlen - length $itag) . $itag;
			}
		}
	}
	$nicks[$$net]->{lc $given} = $nick;
	return $given;
}

sub request_newnick {
	&request_nick;
}

sub request_cnick {
	my($net, $nick, $reqnick, $tagged) = @_;
	my $b4 = $nick->str($net);
	if ($nicks[$$net]{lc $b4} == $nick) {
		delete $nicks[$$net]{lc $b4};
	}
	my $gv = request_nick(@_);
	return $gv;
}

# Release a nick on a remote network (PART/QUIT must be sent BEFORE this)
sub release_nick {
	my($net, $req, $nick) = @_;
	delete $nicks[$$net]->{lc $req};
}

sub all_nicks {
	my $net = shift;
	values %{$nicks[$$net]};
}

sub item {
	my($net, $item) = @_;
	return undef unless defined $item;
	return $net->chan($item) if $item =~ /^#/;
	return $nicks[$$net]{lc $item} if exists $nicks[$$net]{lc $item};
	return $net if $item =~ /\./;
	return undef;
}

1;
