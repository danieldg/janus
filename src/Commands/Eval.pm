# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::Eval;
use strict;
use warnings;
use Data::Dumper;

&Janus::command_add({
	cmd => 'eeval',
	# nope. Not existing
	acl => 1,
	secret => 1,
	code => sub {
		my($src,$dst,$pass, @expr) = @_;
		my $expr = join ' ', @expr;
		return &Janus::jmsg($dst, "Bad syntax") unless $pass && $pass eq $Conffile::netconf{set}{evalpass};
		print "EVAL: $expr\n";
		&Log::audit('EVAL by '.$src->netnick.': '.$expr);
		$expr =~ /(.*)/; # go around taint mode
		$expr = $1;
		my @r = eval $expr;
		@r = $@ if $@ && !@r;
		if (@r) {
			$_ = eval { Data::Dumper::Dumper(\@r); };
			s/\n//g;
			&Janus::jmsg($dst, $_);
		}
	},
});

1;
