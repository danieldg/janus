# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Commands::Request;
use strict;
use warnings;
our($VERSION) = '$Rev$' =~ /(\d+)/;

sub linked {
	my($snn, $dnn, $schan, $dchan) = @_;
	my $snet = $Janus::nets{$snn} or return 0;
	my $dnet = $Janus::nets{$dnn} or return 0;
	my $chan =
		$snet->isa('LocalNetwork') ? $snet->chan($schan) :
		$dnet->isa('LocalNetwork') ? $dnet->chan($dchan) :
		undef;
	$chan && $chan->is_on($snet) && $chan->is_on($dnet);
}

sub code {
	my($nick,$args) = @_;
	$args ||= '';
	my $nname = $nick->homenet()->name();
	if ($args =~ /^del (#\S*) (\S+)/i) {
		if (delete $Links::reqs{$nname}{$2}{$1}) {
			&Janus::jmsg($nick, 'Deleted');
		} else {
			&Janus::jmsg($nick, 'Not found');
		}
	} elsif ($args =~ /^wipe (\S+)/i) {
		if (delete $Links::reqs{$nname}{$1}) {
			&Janus::jmsg($nick, 'Deleted');
		} else {
			&Janus::jmsg($nick, 'Not found');
		}
	} elsif ($args =~ /^(?:pend|pdump) *(\S+)?/i) {
		my $list = $args =~ /^pend/i;
		for my $net ($1 || sort keys %Links::reqs) {
			next if $list && !$Janus::nets{$net};
			my $chanh = $Links::reqs{$net}{$nname} or next;
			for my $schan (sort keys %$chanh) {
				next if $list && linked($net, $nname, $schan, $chanh->{$schan});
				&Janus::jmsg($nick, "$net: $schan $chanh->{$schan}");
			}
		}
		&Janus::jmsg($nick, 'End of list');
	} elsif ($args =~ /^(?:list|dump) *(\S+)?/i) {
		my %chans;
		my $list = $args =~ /^list/i;
		for my $net ($1 || sort keys %{$Links::reqs{$nname}}) {
			my $chanh = $Links::reqs{$nname}{$net} or next;
			for my $schan (keys %$chanh) {
				next if $list && linked($nname, $net, $schan, $chanh->{$schan});
				$chans{$schan} .= ' '.$net;
				$chans{$schan} .= $chanh->{$schan} unless $schan eq $chanh->{$schan};
			}
		}
		for my $chan (sort keys %chans) {
			&Janus::jmsg($nick, $chan.$chans{$chan});
		}
		&Janus::jmsg($nick, 'End of list');
	} else {
		&Janus::jmsg($nick, 'See "help request" for the correct syntax');
	}
}

my $help = [
	"\002REQUEST DEL\002 #chan network  delete a locally added request",
	"\002REQUEST WIPE\002 network       remove \002all\002 link requests for a network",
	"\002REQUEST PEND\002 [network]     list all pending requests (from given network)",
	"\002REQUEST LIST\002 [network]     list all waiting requests (to given network)",
	"\002REQUEST DUMP\002               list all local saved channel relink requsts",
	"\002REQUEST PDUMP\002              list all remote saved channel relink requests",
];

&Janus::command_add({
	cmd => 'request',
	help => 'Displays and manipluates channel link requsts',
	details => $help,
	acl => 1,
	code => \&code,
}, {
	cmd => 'req',
	# no {help}, just presented as 'request'
	details => $help,
	acl => 1,
	code => \&code,
});

1;
