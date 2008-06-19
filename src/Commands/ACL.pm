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
		unless ($args && $args =~ /^(\S+) +(#\S*)(?: +(\S+))?$/) {
			&Interface::jmsg($nick, 'Bad syntax. See "help acl" for syntax');
			return;
		}
		my($m,$cname,$arg) = (lc $1,$2,$3);
		my $hn = $nick->homenet();
		my $chan = $hn->chan($cname,0);
		my $ifo = $Link::request{$hn->name()}{lc $cname};
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
});

1;
