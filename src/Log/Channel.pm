# Copyright (C) 2008-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Log::Channel;
use strict;
use warnings;
use integer;
use Log::Base;
use Scalar::Util 'weaken';
use POSIX 'strftime';
use Persist 'Log::Base';

our @style;
Persist::register_vars(qw(style));
Persist::autoinit(qw(style));

our $loop = 0;

sub output {
	my($log, $ccod, $cat, $msg) = @_;
	$log->name =~ /^(.*?)(#.*)$/ or return;
	my $net = $Janus::nets{$1} or return;
	my $chan = $net->chan($2) or return;
	return if $loop == $Janus::time;
	$loop = $Janus::time;
	my $style = $style[$$log] || 'none';
	if ($style eq 'color') {
		$msg = sprintf "\003\%02d\x1f\%s\x1f \%s", $ccod, $cat, $msg;
	} elsif ($style eq 'bold') {
		$msg = sprintf "\002\x1f\%s\x1f \%s\002", $cat, $msg;
	} else {
		$msg = $cat.' '.$msg;
	}

	Event::insert_full(map +{
		type => 'MSG',
		src => $Interface::janus,
		dst => $chan,
		msgtype => 'PRIVMSG',
		msg => $_
	}, split /[\r\n]+/, $msg);
	$loop = 0;
}

1;
