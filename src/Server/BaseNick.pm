# Copyright (C) 2007-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Server::BaseNick;
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
	$name =~ tr#A-Z[]\\#a-z{}|#;
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
	$name =~ tr#A-Z[]\\#a-z{}|#;
	return $nicks[$$net]{$name} if $nicks[$$net]{$name};
	Log::debug_in($net, "Nick '$name' does not exist; ignoring") unless $_[2];
	undef;
}

# Request a nick on a remote network (CONNECT/JOIN must be sent AFTER this)
sub request_nick {
	my($net, $nick, $reqnick, $tagged) = @_;
	my ($given,$given_lc);
	if ($nick->homenet() eq $net) {
		$given = $given_lc = $reqnick;
		$given_lc =~ tr#A-Z[]\\#a-z{}|#;
	} else {
		$reqnick =~ s/[^0-9a-zA-Z\[\]\\^\-_`{|}]/_/g;
		$reqnick = '_'.$reqnick unless $reqnick =~ /^[A-Za-z\[\]\\^\-_`{|}]/;
		my $maxlen = $net->nicklen();
		$given_lc = $given = substr $reqnick, 0, $maxlen;
		$given_lc =~ tr#A-Z[]\\#a-z{}|#;

		$tagged = 1 if exists $nicks[$$net]->{$given_lc};

		my $tagre = Setting::get(force_tag => $net);
		$tagged = 1 if $tagre && $$nick != 1 && $given =~ /^$tagre$/i;

		if ($tagged) {
			my $tagsep = Setting::get(tagsep => $net);
			my $tag = $tagsep . $nick->homenet()->name();
			my $i = 0;
			$given_lc = $given = substr($reqnick, 0, $maxlen - length $tag) . $tag;
			while (1) {
				$given_lc =~ tr#A-Z[]\\#a-z{}|#;
				last if !exists $nicks[$$net]->{$given_lc};
				my $itag = $tagsep.(++$i).$tag;
				$given = substr($reqnick, 0, $maxlen - length $itag) . $itag;
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
	my $b4 = $nick->str($net);
	$b4 =~ tr#A-Z[]\\#a-z{}|#;
	if ($nicks[$$net]{$b4} == $nick) {
		delete $nicks[$$net]{$b4};
	}
	my $gv = $net->request_nick($nick, $reqnick, $tagged);
	return $gv;
}

# Release a nick on a remote network (PART/QUIT must be sent BEFORE this)
sub release_nick {
	my($net, $req, $nick) = @_;
	$req =~ tr#A-Z[]\\#a-z{}|#;
	delete $nicks[$$net]->{$req};
}

sub all_nicks {
	my $net = shift;
	values %{$nicks[$$net]};
}

sub item {
	my($net, $item) = @_;
	return undef unless defined $item;
	$item =~ tr#A-Z[]\\#a-z{}|#;
	return $net->chan($item) if $item =~ /^#/;
	return $nicks[$$net]{$item} if exists $nicks[$$net]{$item};
	return $net if $item =~ /\./;
	return undef;
}

1;
