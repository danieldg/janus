# Copyright (C) 2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Log::Channel;
use strict;
use warnings;
use integer;
use Log::Base;
use Scalar::Util 'weaken';
use POSIX 'strftime';
use Persist 'Log::Base';

sub output {
	my $log = shift;
	$log->name =~ /^(.*?)(#.*)$/ or return;
	my $net = $Janus::nets{$1} or return;
	my $chan = $net->chan($2) or return;
	my $msg = sprintf "\003\%02d\x1f\%s\x1f \%s", @_;
	&Janus::insert_full(map +{
		type => 'MSG',
		src => $Interface::janus,
		dst => $chan,
		msgtype => 'PRIVMSG',
		msg => $_
	}, split /[\r\n]+/, $msg);
}

1;
