# Copyright (C) 2007-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Util::BaseNick;
use LocalNetwork;
use Persist 'LocalNetwork';
use Scalar::Util qw(isweak weaken);
use strict;
use warnings;

our @nicks;
Persist::register_vars('nicks');

sub _init {
	my $net = shift;
	$nicks[$$net] = {};
}

sub mynick {
	my($net, $name) = @_;
	$name = $net->lc($name);
	my $nick = $nicks[$$net]{$name};
	unless ($nick) {
		Log::debug_in($net, "Nick '$name' does not exist; ignoring");
		return undef;
	}
	if ($nick->homenet() ne $net) {
		Log::err_in($net, "Nick '$name' is from network '".$nick->homenet()->name().
			"' but was sourced locally");
		return undef;
	}
	return $nick;
}

sub nick {
	my($net, $name) = @_;
	$name = $net->lc($name);
	return $nicks[$$net]{$name} if $nicks[$$net]{$name};
	Log::debug_in($net, "Nick '$name' does not exist; ignoring") unless $_[2];
	undef;
}

# Request a nick on a remote network (CONNECT/JOIN must be sent AFTER this)
sub request_nick {
	my($net, $nick, $reqnick, $tagged) = @_;
	my ($given,$given_lc);
	if ($nick->homenet() eq $net) {
		$given = $reqnick;
		$given_lc = $net->lc($given);
	} else {
		$reqnick =~ s/[^0-9a-zA-Z\[\]\\^\-_`{|}]/_/g;
		$reqnick = '_'.$reqnick unless $reqnick =~ /^[A-Za-z\[\]\\^\-_`{|}]/;
		my $maxlen = $net->nicklen();
		$given = substr $reqnick, 0, $maxlen;
		$given_lc = $net->lc($given);

		$tagged = 1 if exists $nicks[$$net]->{$given_lc};

		my $tagre = Setting::get(force_tag => $net);
		$tagged = 1 if $tagre && $$nick != 1 && $given =~ /^$tagre$/i;

		if ($tagged) {
			my $tagsep = Setting::get(tagsep => $net);
			my $tag = $tagsep . $nick->homenet()->name();
			my $i = 0;
			$given = substr($reqnick, 0, $maxlen - length $tag) . $tag;
			$given_lc = $net->lc($given);
			while (exists $nicks[$$net]->{$given_lc}) {
				my $itag = $tagsep.(++$i).$tag;
				$given = substr($reqnick, 0, $maxlen - length $itag) . $itag;
				$given_lc = $net->lc($given);
			}
		}
	}
	$nicks[$$net]->{$given_lc} = $nick;
	return $given;
}

sub request_newnick {
	my $n = shift;
	$n->request_nick(@_);
}

sub request_cnick {
	my($net, $nick, $reqnick, $tagged) = @_;
	$tagged ||= 0;
	my $b4 = $net->lc($nick->str($net));
	if ($tagged != 2 && $nicks[$$net]{$b4} == $nick) {
		delete $nicks[$$net]{$b4};
	}
	my $gv = $net->request_nick($nick, $reqnick, $tagged);
	if ($tagged == 2 && $nicks[$$net]{$b4} == $nick) {
		delete $nicks[$$net]{$b4};
	}
	return $gv;
}

# Release a nick on a remote network (PART/QUIT must be sent BEFORE this)
sub release_nick {
	my($net, $req, $nick) = @_;
	delete $nicks[$$net]->{$net->lc($req)};
}

sub all_nicks {
	my $net = shift;
	values %{$nicks[$$net]};
}

sub item {
	my($net, $item) = @_;
	return undef unless defined $item;
	$item = $net->lc($item);
	return $net->chan($item) if $item =~ /^#/;
	return $nicks[$$net]{$item} if exists $nicks[$$net]{$item};
	return $net if $item =~ /\./;
	return undef;
}

sub _out {
	my($net,$itm) = @_;
	return '' unless defined $itm;
	return $itm =~ / / || $itm eq '' ? ':'.$itm : $itm unless ref $itm;
	if ($itm->isa('Nick')) {
		return $itm->str($net) if $itm->is_on($net);
		return $itm->homenet()->jname();
	} elsif ($itm->isa('Channel')) {
		return $itm->str($net);
	} elsif ($itm->isa('Network')) {
		return $net->cparam('linkname') if $itm eq $net;
		return $itm->jname();
	} else {
		Log::warn_in($net,"Unknown _out item $itm");
	}
	'';
}

1;
