# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Commands::Eval;
use strict;
use warnings;
use Data::Dumper;

our($VERSION) = '$Rev$' =~ /(\d+)/;

&Janus::command_add({
	cmd => 'eeval',
	# nope. Not existing
	code => sub {
		my($nick,$expr) = @_;
		return &Janus::jmsg($nick, "You must be an IRC operator to use this command") unless $nick->has_mode('oper');
		return &Janus::jmsg($nick, "Bad syntax") unless $expr =~ s/^(\S+)\s+//;
		return &Janus::jmsg($nick, "Bad syntax") unless $1 && $1 eq $Conffile::netconf{set}{evalpass};
		print "EVAL: $expr\n";
		my @r = eval $expr;
		@r = $@ if $@ && !@r;
		if (@r) {
			$_ = Data::Dumper::Dumper(\@r);
			s/\n//g;
			&Janus::jmsg($nick, $_);
		}
	},
});

1;
