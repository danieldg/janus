# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::Request;
use strict;
use warnings;

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
		my $net = $Janus::nets{$2};
		if ($net) {
			&Janus::append(+{
				type => 'REQDEL',
				src => $nick,
				snet => $nick->homenet(),
				dnet => $net,
				dst => $net,
				name => $1,
			});
		} else {
			if (delete $Link::reqs{$nname}{$2}{$1}) {
				&Janus::jmsg($nick, 'Deleted');
			} else {
				&Janus::jmsg($nick, 'Not found');
			}
		}
	} elsif ($args =~ /^reject (#\S*) (\S+)/i) {
		my $net = $Janus::nets{$2} or return &Janus::jmsg($nick, 'Network not found');
		&Janus::append(+{
			type => 'REQDEL',
			src => $nick,
			snet => $net,
			dnet => $nick->homenet(),
			dst => $net,
			name => $1,
		});
	} elsif ($args =~ /^wipe (\S+)/i) {
		if (delete $Link::reqs{$nname}{$1}) {
			&Janus::jmsg($nick, 'Deleted');
		} else {
			&Janus::jmsg($nick, 'Not found');
		}
	} elsif ($args =~ /^(?:pend|pdump) *(\S+)?/i) {
		my $list = $args =~ /^pend/i;
		for my $net ($1 || sort keys %Link::reqs) {
			next if $list && !$Janus::nets{$net};
			my $chanh = $Link::reqs{$net}{$nname} or next;
			for my $schan (sort keys %$chanh) {
				my $ifo = $chanh->{$schan};
				my $dchan = ref $ifo ? $ifo->{dst} : $ifo;
				next if $list && linked($net, $nname, $schan, $dchan);
				&Janus::jmsg($nick, "$net: $schan $dchan".
					(ref $ifo ? " by $ifo->{nick} on ".gmtime($ifo->{time}) : ''));
			}
		}
		&Janus::jmsg($nick, 'End of list');
	} elsif ($args =~ /^linkall/i) {
		for my $net (sort keys %Link::reqs) {
			next if !$Janus::nets{$net};
			my $chanh = $Link::reqs{$net}{$nname} or next;
			for my $schan (sort keys %$chanh) {
				my $ifo = $chanh->{$schan};
				my $dchan = ref $ifo ? $ifo->{dst} : $ifo;
				next if linked($net, $nname, $schan, $dchan);
				&Janus::append(+{
					type => 'LINKREQ',
					src => $nick,
					dst => $Janus::nets{$net},
					net => $nick->homenet(),
					slink => $schan,
					dlink => $dchan,
					reqby => $nick->realhostmask(),
					reqtime => $Janus::time,
				});
			}
		}
		&Janus::jmsg($nick, 'All pending requsts linked');
	} elsif ($args =~ /^autolink/i) {
		for my $net (keys %Link::reqs) {
			next if !$Janus::nets{$net};
			my $chanh = $Link::reqs{$net}{$nname} or next;
			for my $schan (sort keys %$chanh) {
				my $ifo = $chanh->{$schan};
				my $dchan = ref $ifo ? $ifo->{dst} : $ifo;
				next unless $Link::reqs{$nname}{$net}{$dchan};
				next if linked($net, $nname, $schan, $dchan);
				&Janus::append(+{
					type => 'LINKREQ',
					src => $nick,
					dst => $Janus::nets{$net},
					net => $nick->homenet(),
					slink => $schan,
					dlink => $dchan,
					reqby => $nick->realhostmask(),
					reqtime => $Janus::time,
				});
			}
		}
		&Janus::jmsg($nick, 'All pre-existing requsts linked');
	} elsif ($args =~ /^(?:list|dump) *(\S+)?/i) {
		my %chans;
		my $list = $args =~ /^list/i;
		for my $net ($1 || sort keys %{$Link::reqs{$nname}}) {
			my $chanh = $Link::reqs{$nname}{$net} or next;
			for my $schan (keys %$chanh) {
				my $ifo = $chanh->{$schan};
				my $dchan = ref $ifo ? $ifo->{dst} : $ifo;
				next if $list && linked($nname, $net, $schan, $dchan);
				$chans{$schan} .= ' '.$net;
				$chans{$schan} .= $dchan unless $schan eq $dchan;
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
	"Pending requests (remote networks waiting for local approval):",
	" \002REQUEST PEND\002 [network]       List all pending requests (from given network)",
	" \002REQUEST LINKALL\002              Link all pending requests",
	" \002REQUEST REJECT\002 #chan network Reject the given request",
	" \002REQUEST PDUMP\002                List all saved channel relink requests",
	"Waiting requests (local channels waiting for remote approval):",
	" \002REQUEST LIST\002 [network]       List all waiting requests (to given network)",
	" \002REQUEST DEL\002 #chan network    Delete a locally added request",
	" \002REQUEST WIPE\002 network         Remove \002all\002 link requests for a network",
	" \002REQUEST DUMP\002                 List all local saved channel relink requsts",
	"Misc. Commands",
	" \002REQUEST AUTOLINK\002             Link all channels that would be autolinked on a netsplit",
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

0;
