# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::ACL;
use strict;
use warnings;

&Event::command_add({
	cmd => 'acl',
	help => 'Manages access control for shared channels',
	section => 'Channel',
	details => [
		"\002ACL LIST\002 #channel          Lists ACL entries for the channel",
		"\002ACL ALLOW\002 #channel net     Allows a network access to link",
		"\002ACL DENY\002 #channel net      Denies a network access to link",
		"\002ACL DEL\002 #channel net       Removes a network's ACL entry",
		"\002ACL DEFAULT\002 #channel (+/-) Sets the default access for networks",
	],
	api => '=src =replyto $ localchan ?$',
	code => sub {
		my($src,$dst, $m, $chan, $arg) = @_;
		$m = lc $m;
		my $acl = $m eq 'list' ? 'info' : 'create';
		return unless &Account::chan_access_chk($src, $chan, $acl, $dst);
		my $hn = $chan->homenet;
		my $cname = lc $chan->str($hn);
		my $ifo = $Link::request{$hn->name}{$cname};
		unless ($ifo && $ifo->{mode}) {
			&Interface::jmsg($dst, 'That channel is not shared');
			return;
		}
		if ($m eq 'list') {
			&Interface::jmsg($dst, 'Default: '.($ifo->{mode} == 1 ? 'allow' : 'deny'));
			return unless $ifo->{ack};
			for my $nn (keys %{$ifo->{ack}}) {
				&Interface::jmsg($dst, sprintf '%8s %s', $nn,
					($ifo->{ack}{$nn} == 1 ? 'allow' : 'deny'));
			}
		} elsif ($m eq 'allow') {
			return &Interface::jmsg($dst, 'Cannot find that network') unless $Janus::nets{$arg};
			$ifo->{ack}{$arg} = 1;
			&Interface::jmsg($dst, 'Done');
		} elsif ($m eq 'deny') {
			return &Interface::jmsg($dst, 'Cannot find that network') unless $Janus::nets{$arg};
			$ifo->{ack}{$arg} = 2;
			&Interface::jmsg($dst, 'Done');
		} elsif ($m eq 'del' && $arg) {
			if (delete $ifo->{ack}{$arg}) {
				&Interface::jmsg($dst, 'Deleted');
			} else {
				&Interface::jmsg($dst, 'Cannot find that network');
			}
		} elsif ($m eq 'default' && $arg) {
			my $v = $ifo->{mode};
			$v = 1 if $arg =~ s/^\+//;
			$v = 2 if $arg =~ s/^\-//;
			$ifo->{mode} = $v;
			Interface::jmsg($dst, 'Done');
		}
	}
}, {
	cmd => 'accept',
	help => 'Links a channel to a network that has previously requested a link',
	section => 'Channel',
	details => [
		"\002ACCEPT\002 #channel net",
		'This command is useful if an ACL has blocked access to a network, or if the',
		'link request was made before the destination channel was created.',
	],
	api => 'act =src =replyto =tochan homenet chan net',
	code => sub {
		my($genact, $src, $dst, $tochan, $snet, $chan, $dnet) = @_;
		my $dnname = $dnet->name;
		unless ($tochan) {
			&Janus::jmsg('Run this command on your own server') if $snet->jlink;

			return unless &Account::chan_access_chk($src, $chan, 'create', $dst);
			$tochan = lc $chan->homename;

			my $difo = $Link::request{$snet->name}{$tochan};
			unless ($difo && $difo->{mode}) {
				&Janus::jmsg($dst, 'That channel is not shared');
				return;
			}
			if ($difo->{mode} == 2) {
				$difo->{ack}{$dnname} = 1;
			} else {
				delete $difo->{ack}{$dnname};
			}

			&Event::reroute_cmd($genact, $dnet->jlink);
		}
		return if $dnet->jlink;
		my $hname = $snet->name;
		for my $dcname (keys %{$Link::request{$dnname}}) {
			my $ifo = $Link::request{$dnname}{$dcname};
			next unless $ifo->{net} eq $hname && lc $ifo->{chan} eq $tochan;
			next if $ifo->{mode};
			my $chan = $dnet->chan($dcname, 1);
			&Event::append(+{
				type => 'LINKREQ',
				chan => $chan,
				dst => $snet,
				dlink => $tochan,
				reqby => $ifo->{mask},
				reqtime => $ifo->{time},
				linkfile => 1,
			});
		}
	},
});

1;
