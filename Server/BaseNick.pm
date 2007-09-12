# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Server::BaseNick;
use LocalNetwork;
use Persist 'LocalNetwork';
use Scalar::Util qw(isweak weaken);
use strict;
use warnings;

our($VERSION) = '$Rev$' =~ /(\d+)/;

sub _init {
	my $net = shift;
}

sub mynick {
	my($net, $name) = @_;
	my $nick = $Janus::nicks{lc $name};
	unless ($nick) {
		print "Nick '$name' does not exist; ignoring\n";
		return undef;
	}
	if ($nick->homenet()->id() ne $net->id()) {
		print "Nick '$name' is from network '".$nick->homenet()->id().
			"' but was sourced from network '".$net->id()."'\n";
		return undef;
	}
	return $nick;
}

sub nick {
	my($net, $name) = @_;
	return $Janus::nicks{lc $name} if $Janus::nicks{lc $name};
	print "Nick '$name' does not exist; ignoring\n" unless $_[2];
	undef;
}

sub nick_collide {
	my($net, $name, $new) = @_;
	my $old = delete $Janus::nicks{lc $name};
	unless ($old) {
		$Janus::nicks{lc $name} = $new;
		return 1;
	}
	my $tsctl = $old->ts() <=> $new->ts();

	$Janus::nicks{lc $name} = $new if $tsctl > 0;
	$Janus::nicks{lc $name} = $old if $tsctl < 0;
	
	my @rv = ($tsctl > 0);
	if ($tsctl >= 0) {
		# old nick lost, reconnect it
		if ($old->homenet()->id() eq $net->id()) {
			warn "Nick collision on home network!";
		} else {
			push @rv, +{
				type => 'RECONNECT',
				dst => $new,
				net => $net,
				killed => 1,
				nojlink => 1,
			};
		}
	}
	@rv;
}

# Request a nick on a remote network (CONNECT/JOIN must be sent AFTER this)
sub request_nick {
	my($net, $nick, $reqnick, $tagged) = @_;
	my $given;
	if ($nick->homenet()->id() eq $net->id()) {
		$given = $reqnick;
	} else {
		$reqnick =~ s/[^0-9a-zA-Z\[\]\\^\-_`{|}]/_/g;
		$reqnick = '_'.$reqnick unless $reqnick =~ /^[A-Za-z\[\]\\^\-_`{|}]/;
		my $maxlen = $net->nicklen();
		$given = substr $reqnick, 0, $maxlen;

		$tagged = 1 if exists $Janus::nicks{lc $given};

		my $tagre = $net->param('force_tag');
		$tagged = 1 if $tagre && $given =~ /$tagre/;
		
		if ($tagged) {
			my $tagsep = $net->param('tag_prefix');
			$tagsep = '/' unless defined $tagsep;
			my $tag = $tagsep . $nick->homenet()->id();
			my $i = 0;
			$given = substr($reqnick, 0, $maxlen - length $tag) . $tag;
			while (exists $Janus::nicks{lc $given}) {
				my $itag = $tagsep.(++$i).$tag; # it will find a free nick eventually...
				$given = substr($reqnick, 0, $maxlen - length $itag) . $itag;
			}
		}
	}
	$Janus::nicks{lc $given} = $nick;
	return $given;
}

sub request_newnick {
	&request_nick;
}

sub request_cnick {
	my($net, $nick, $reqnick, $tagged) = @_;
	my $b4 = $nick->str($net);
	my $gv = request_nick(@_);
	delete $Janus::nicks{lc $b4};
	$gv;
}

# Release a nick on a remote network (PART/QUIT must be sent BEFORE this)
sub release_nick {
	my($net, $req, $nick) = @_;
	delete $Janus::nicks{lc $req};
}

sub all_nicks {
	my $net = shift;
	values %Janus::nicks;
}

sub item {
	my($net, $item) = @_;
	return undef unless defined $item;
	return $net->chan($item) if $item =~ /^#/;
	return $Janus::nicks{lc $item} if exists $Janus::nicks{lc $item};
	return $net if $item =~ /\./;
	return undef;
}

1;
