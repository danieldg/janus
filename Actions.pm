# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Actions;
use Object::InsideOut;
use Persist;
use strict;
use warnings;

our($VERSION) = '$Rev$' =~ /(\d+)/;

# item => Class
#   multiple classes space separated
#   Begins with a ?    only checks if defined
#   '@' or '%'         unblessed array or hash
#   '$'                checks that it is a string/number
#   '!'                verifies that it is undef
#   ''                 allows anything

=h2 Internal Janus events

=over

=item NETLINK Sent when a connection to/from janus is initalized 

=item BURST Sent when a connection is ready to start syncing data

=item LINKED Sent when a connection is fully linked

=item NETSPLIT Disconnects a network from janus

=item RAW Internal network action; do not intercept or inspect

=back

=h2 Nick-Network motion events

=over

=item NEWNICK Nick has connected to its home net

=item CONNECT Janus nick introduced to a remote net

=item RECONNECT Janus nick reintroduced to a remote net

=item QUIT Janus nick leaves home net, possibly involuntarily

=back

=h2 Nick-Channel motion events

=item JOIN Nick joins a channel, possibly coming in with some modes (op)

=item PART Nick leaves a channel

=item KICK Nick involuntarily leaves a channel

=back

=h2 Channel state changes

=item MODE Basic mode change

=over 

=item n nick access level
=item l list (bans)
=item v value (key)
=item s value-on-set (limit)
=item r regular (moderate)
=item t tristate (private/secret; this is planned, not implemented)

=back

=item TIMESYNC Channel creation timestamp modification

=item TOPIC Channel topic change

=back

=h2 Nick state changes

=over

=item NICK nickname change

=item UMODE nick mode change

=item NICKINFO nick metainformation change

=back

=h2 Communication

=over

=item MSG Overall one-to-some messaging

=item WHOIS remote idle queries

=item CHATOPS internetwork administrative communication

=back

=h2 Janus commands

=over

=item LINKREQ initial request to link a channel

=item LSYNC internal sync for InterJanus channel links

=item LINK final atomic linking and mode merge

=back

=cut

__PERSIST__
__CODE__

my %spec = (

	NETLINK => {
		net => 'Network',
	},
	LINKED => {
		net => 'Network',
	},
	BURST => {
		net => 'Network',
	},
	NETSPLIT => {
		net => 'Network',
		msg => '',
	},

	NEWNICK => {
		dst => 'Nick',
	},
	CONNECT => {
		dst => 'Nick',
		net => 'Network',
	}, 
	RECONNECT => {
		dst => 'Nick',
		net => 'Network',
		killed => '$', # 1 = reintroduce, 0 = renick
	},
	QUIT => {
		dst => 'Nick',
		msg => '$',
		killer => '?Nick Network',
		netsplit_quit => '?$',
	},

	JOIN => {
		src => 'Nick',
		dst => 'Channel',
		mode => '?%',
	},
	PART => {
		src => 'Nick',
		dst => 'Channel',
		msg => '?$',
	},
	KICK => {
		src => 'Nick Network',
		dst => 'Channel',
		kickee => 'Nick',
		msg => '$',
	},

	MODE => {
		src => 'Nick Network',
		dst => 'Channel',
		mode => '@',
		args => '@',
	},
	TIMESYNC => {
		dst => 'Channel',
		wipe => '$',
		ts => '$',
		oldts => '$',
	},
	TOPIC => {
		dst => 'Channel',
		topicset => '$',
		topicts => '$',
		topic => '$',
	},

	NICK => {
		dst => 'Nick',
		nick => '$',
		nickts => '?$',
	},
	UMODE => {
		dst => 'Nick',
		mode => '@',
	},
	NICKINFO => {
		dst => 'Nick',
		item => '$',
		value => '?$',
	},

	MSG => {
		src => 'Nick Network',
		dst => 'Nick Channel',
		msgtype => '$',
		msg => '$ @',
		prefix => '?$',
	},
	WHOIS => {
		src => 'Nick',
		dst => 'Nick',
	},
	CHATOPS => {
		src => 'Nick',
		msg => '$',
	},

	LINKREQ => {
	},
	LSYNC => {
	},
	LINK => {
	},
	DELINK => {
	},
);

my %ignore;
$ignore{$_} = 1 for qw/type src dst except sendto/;

&Janus::hook_add(ALL => validate => sub {
	my $act = shift;
	my $itm = $act->{type};
	my $check = $spec{$itm};
	unless ($check) {
		return undef if $itm eq 'RAW';
		print "Unknown action type $itm\n";
		return undef;
	}
	KEY: for my $k (keys %$check) {
		$@ = "Fail: Key $k in $itm";
		$_ = $$check{$k};
		my $v = $act->{$k};
		if (s/^\?//) {
			return 0 unless defined $v;
		} else {
			return 1 unless defined $v;
		}
		my $r = 0;
		for (split /\s+/) {
			next KEY if eval {
				/\$/ ? (defined $v && '' eq ref $v) :
				/\@/ ? (ref $v && 'ARRAY' eq ref $v) :
				/\%/ ? (ref $v && 'HASH' eq ref $v) :
				(ref $v && $v->isa($_));
			};
		}
		$@ = "Invalid value $v for key '$k' in action $itm";
		return 1 unless $r;
	}
	for my $k (keys %$act) {
		next if $ignore{$k} or exists $check->{$k};
		print "Warning: unknown key $k in action $itm\n";
	}
	undef;
});

1;
