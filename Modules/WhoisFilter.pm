# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Modules::WhoisFilter;
use strict;
use warnings;
use Persist;

our($VERSION) = '$Rev$' =~ /(\d+)/;

my @unfiltered :PersistAs(Nick,unfilter);

&Janus::command_add(+{
	cmd => 'whoisfilter',
	help => 'Manages the remote-user /whois notice filter for your nick',
	details => [
		"Use: \002WHOISFILTER\002 1|0",
		'By default, if this module is loaded, you are only notified when a',
		'user does /whois nick nick on you. This command disables the filter',
		'for your nick, until the next netsplit',
	],
	acl => 1,
	code => sub {
		my($nick,$arg) = @_;
		my $on = $arg && $arg !~ /off/;
		$unfiltered[$$nick] = !$on;
		&Janus::jmsg($nick, 'Whois filtering is now '.($on ? 'on' : 'off').' for your nick');
	}
});

&Janus::hook_add(
	MSG => check => sub {
		my $act = shift;
		if ($act->{msgtype} eq 'NOTICE' && $act->{src}->isa('Network')) {
			my $dst = $act->{dst};
			return undef unless $dst->isa('Nick');
			return undef if $unfiltered[$$dst];
			return 1 if $act->{msg} =~ m#^\*\*\* \S+ \(\S+\) did a /\S+ on you.$#;
		}
		undef;
	},
);

1;
