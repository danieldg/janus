# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::ACL;
use strict;
use warnings;

&Janus::command_add({
	cmd => 'acl',
	help => 'Manages access control for shared channels',
	details => [
		"\002ACL LIST\002 #channel          Lists ACL entries for the channel",
		"\002ACL ADD\002 #channel (+/-)net  Allows or denies a network access",
		"\002ACL DEL\002 #channel net       Removes a network's ACL entry",
		"\002ACL DEFAULT\002 #channel (+/-) Sets the default access for networks",
	],
	code => sub {
		my($nick,$args) = @_;
		unless ($args && $args =~ /^(\S+) +(#\S*)(?: +(\S+))?\s*$/) {
			&Interface::jmsg($nick, 'Bad syntax. See "help acl" for syntax');
			return;
		}
		my($m,$cname,$arg) = (lc $1,$2,$3);
		my $hn = $nick->homenet;
		my $chan = $hn->chan($cname,0);
		my $ifo = $Link::request{$hn->name}{lc $cname};
		unless ($chan) {
			&Interface::jmsg($nick, 'Cannot find that channel');
			return;
		}
		unless ($ifo && $ifo->{mode}) {
			&Interface::jmsg($nick, 'That channel is not shared');
			return;
		}
		if ($m eq 'list') {
			&Interface::jmsg($nick, 'Default: '.($ifo->{mode} == 1 ? 'allow' : 'deny'));
			return unless $ifo->{ack};
			for my $nn (keys %{$ifo->{ack}}) {
				&Interface::jmsg($nick, sprintf '%4s %s', $nn,
					($ifo->{ack}{$nn} == 1 ? 'allow' : 'deny'));
			}
		} elsif ($m eq 'add' && $arg) {
			my $v = 3 - $ifo->{mode};
			$v = 1 if $arg =~ s/^\+//;
			$v = 2 if $arg =~ s/^\-//;
			return &Interface::jmsg($nick, 'Cannot find that network') unless $Janus::nets{$arg};
			$ifo->{ack}{$arg} = $v;
		} elsif ($m eq 'del' && $arg) {
			if (delete $ifo->{ack}{$arg}) {
				&Interface::jmsg($nick, 'Deleted');
			} else {
				&Interface::jmsg($nick, 'Cannot find that network');
			}
		} elsif ($m eq 'default' && $arg) {
			my $v = $ifo->{mode};
			$v = 1 if $arg =~ s/^\+//;
			$v = 2 if $arg =~ s/^\-//;
			$ifo->{mode} = $v;
		}
	}
}, {
	cmd => 'accept',
	help => 'Links a channel to a network that has previously requested a link',
	details => [
		"\002ACCEPT\002 #channel net",
		'This command is useful if an ACL has blocked access to a network, or if the',
		'link request was made before the destination channel was created.',
	],
	code => sub {
		my($nick,$args) = @_;
		unless ($args && $args =~ /(#\S*) +(\S+)/) {
			&Interface::jmsg($nick, 'Bad syntax. See "help accept" for syntax');
			return;
		}
		my($cname,$dnname) = (lc $1,$2);
		my $hn = $nick->homenet;
		my $hname = $hn->name;
		my $dnet = $Janus::nets{$dnname};
		return Interface::jmsg($nick, 'Cannot find that network') unless $dnet;
		unless ($hn->jlink) {
			my $chan = $hn->chan($cname, 0);
			my $difo = $Link::request{$hname}{lc $cname};
			return Interface::jmsg($nick, 'Cannot find that channel') unless $chan;
			unless ($difo && $difo->{mode}) {
				&Interface::jmsg($nick, 'That channel is not shared');
				return;
			}
			if ($difo->{mode} == 2) {
				$difo->{ack}{$dnname} = 1;
			} else {
				delete $difo->{ack}{$dnname};
			}
		}
		if ($dnet->jlink) {
			# TODO this may not be the best way to do it
			&Janus::append(+{
				type => 'MSG',
				src => $nick,
				dst => $Interface::janus,
				msgtype => 'PRIVMSG',
				sendto => $dnet->jlink,
				msg => '@'.$dnet->jlink->id." accept $args",
			});
		} else {
			for my $dcname (keys %{$Link::request{$dnname}}) {
				my $ifo = $Link::request{$dnname}{$dcname};
				next unless $ifo->{net} eq $hname && lc $ifo->{chan} eq lc $cname;
				next if $ifo->{mode};
				my $chan = $dnet->chan($dcname, 1);
				&Janus::append(+{
					type => 'LINKREQ',
					chan => $chan,
					dst => $hn,
					dlink => $cname,
					reqby => $ifo->{mask},
					reqtime => $ifo->{time},
					linkfile => 1,
				});
			};
		}
	},
});

1;
