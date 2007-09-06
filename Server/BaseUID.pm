# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Server::BaseUID;
use LocalNetwork;
use Persist 'LocalNetwork';
use Scalar::Util qw(isweak weaken);
use strict;
use warnings;

our($VERSION) = '$Rev$' =~ /(\d+)/;

my @uids :Persist(uids);
my @nick2uid :Persist(nickuid);

sub _init {
	my $net = shift;
	$uids[$$net] = {};
}

sub mynick {
	my($net, $name) = @_;
	my $nick = $uids[$$net]{uc $name};
	unless ($nick) {
		print "UID '$name' does not exist; ignoring\n";
		return undef;
	}
	if ($nick->homenet()->id() ne $net->id()) {
		print "UID '$name' is from network '".$nick->homenet()->id().
			"' but was sourced from network '".$net->id()."'\n";
		return undef;
	}
	return $nick;
}

sub nick {
	my($net, $name) = @_;
	return $uids[$$net]{uc $name} if $uids[$$net]{uc $name};
	print "UID '$name' does not exist; ignoring\n" unless $_[2];
	undef;
}

sub register_nick {
	my($net, $new) = @_;
	my $new_uid = $new->info('home_uid');
	my $name = $new->str($net);
	my $old_uid = delete $nick2uid[$$net]{lc $name};
	unless ($old_uid) {
		$nick2uid[$$net]{lc $name} = $new_uid;
		return ();
	}
	my $old = $uids[$$net]{uc $old_uid} or warn;
	my $tsctl = $old->ts() <=> $new->ts();

	if ($new->info('ident') eq $old->info('ident') && $new->info('host') eq $old->info('host')) {
		# this is a ghosting nick, we REVERSE the normal timestamping
		$tsctl = -$tsctl;
	}
	
	if ($tsctl >= 0) {
		# TODO ask inspircd devs what to do if $tsctl == 0
		$nick2uid[$$net]{lc $name} = $new_uid;
		$nick2uid[$$net]{lc $old_uid} = $old_uid;
		return +{
			type => 'NICK',
			dst => $old,
			nick => $old_uid,
			nickts => 1, # this is a UID-based nick, it ALWAYS wins
		};
	} else {
		$nick2uid[$$net]{lc $new_uid} = $new_uid;
		$nick2uid[$$net]{lc $name} = $old_uid;
		return +{
			type => 'NICK',
			dst => $new,
			nick => $new_uid,
			nickts => 1,
		};
	}
}

## TODO ## this is where I stopped implementation

# Request a nick on a remote network (CONNECT/JOIN must be sent AFTER this)
sub request_nick {
	my($net, $nick, $reqnick, $tagged) = @_;
	my $given;
	if ($nick->homenet()->id() eq $net->id()) {
		$given = $reqnick;
	} else {
		$reqnick =~ s/[^0-9a-zA-Z\[\]\\^\-_`{|}]/_/g;
		my $maxlen = $net->nicklen();
		$given = substr $reqnick, 0, $maxlen;

		$tagged = 1 if exists $nicks[$$net]->{lc $given};

		my $tagre = $net->param('force_tag');
		$tagged = 1 if $tagre && $given =~ /$tagre/;
		
		if ($tagged) {
			my $tagsep = $net->param('tag_prefix');
			$tagsep = '/' unless defined $tagsep;
			my $tag = $tagsep . $nick->homenet()->id();
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

# Release a nick on a remote network (PART/QUIT must be sent BEFORE this)
sub release_nick {
	my($net, $req) = @_;
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

&Janus::hook_add(
	NETSPLIT => cleanup => sub {
		my $act = shift;
		my $net = $act->{net};
		return unless $net->isa(__PACKAGE__);
		my $tid = $net->id();
		if (%{$nicks[$$net]}) {
			my @clean;
			warn "nicks remain after a netsplit, killing...";
			for my $nick ($net->all_nicks()) {
				push @clean, +{
					type => 'KILL',
					dst => $nick,
					net => $net,
					msg => 'JanusSplit',
					nojlink => 1,
				};
			}
			&Janus::insert_full(@clean);
			warn "nicks still remain after netsplit kills: ".join ',', keys %{$nicks[$$net]} if %{$nicks[$$net]};
			$nicks[$$net] = undef;
		}
	},
);

1;
