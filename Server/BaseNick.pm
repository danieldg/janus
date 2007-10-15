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

my @nicks  :Persist(nicks);

sub _init {
	my $net = shift;
	$nicks[$$net] = {};
}

sub mynick {
	my($net, $name) = @_;
	my $nick = $nicks[$$net]{lc $name};
	unless ($nick) {
		print "Nick '$name' does not exist; ignoring\n";
		return undef;
	}
	if ($nick->homenet() ne $net) {
		print "Nick '$name' is from network '".$nick->homenet()->id().
			"' but was sourced from network '".$net->id()."'\n";
		return undef;
	}
	return $nick;
}

sub nick {
	my($net, $name) = @_;
	return $nicks[$$net]{lc $name} if $nicks[$$net]{lc $name};
	print "Nick '$name' does not exist; ignoring\n" unless $_[2];
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

	$nicks[$$net]->{lc $name} = $new if $tsctl > 0;
	$nicks[$$net]->{lc $name} = $old if $tsctl < 0;
	
	my @rv = ($tsctl > 0);
	if ($tsctl >= 0) {
		# old nick lost, reconnect it
		if ($old->homenet() eq $net) {
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
	if ($nick->homenet() eq $net) {
		$given = $reqnick;
	} else {
		$reqnick =~ s/[^0-9a-zA-Z\[\]\\^\-_`{|}]/_/g;
		$reqnick = '_'.$reqnick unless $reqnick =~ /^[A-Za-z\[\]\\^\-_`{|}]/;
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

sub request_newnick {
	&request_nick;
}

sub request_cnick {
	my($net, $nick, $reqnick, $tagged) = @_;
	my $b4 = $nick->str($net);
	my $gv = request_nick(@_);
	delete $nicks[$$net]->{lc $b4};
	$gv;
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

&Janus::hook_add(
	NETSPLIT => cleanup => sub {
		my $act = shift;
		my $net = $act->{net};
		return unless $net->isa(__PACKAGE__);
		my $tid = $net->id();
		return unless %{$nicks[$$net]};
		my @clean;
		my %chan_reclaim;
		for my $nick ($net->all_nicks()) {
			$_->is_on($net) and $chan_reclaim{$_} = $_ for $nick->all_chans();
		}
		warn "channels remain in netsplit cleanup: ".
			join ' ', map $_->str($net), values %chan_reclaim if %chan_reclaim;
		for my $ch (values %chan_reclaim) {
			push @clean, +{
				type => 'DELINK',
				dst => $ch,
				net => $net,
				netsplit_quit => 1,
				reason => 'Delink2',
			};
		}
		&Janus::insert_full(@clean);

		@clean = ();
		warn "nicks remain after a netsplit, killing..." if %{$nicks[$$net]};
		for my $nick ($net->all_nicks()) {
			if ($nick->homenet() eq $net) {
				push @clean, +{
					type => 'QUIT',
					src => $net,
					dst => $nick,
					msg => 'JanusSplit',
					nojlink => 1,
				};
			} else {
				push @clean, +{
					type => 'KILL',
					src => $Janus::interface,
					dst => $nick,
					net => $net,
					msg => 'JanusSplit',
					nojlink => 1,
				};
			}
		}
		&Janus::insert_full(@clean);
		warn "nicks still remain after netsplit kills: ".join ',', keys %{$nicks[$$net]} if %{$nicks[$$net]};
		$nicks[$$net] = undef;
	},
);

1;
