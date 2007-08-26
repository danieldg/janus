# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Commands::Core;
use strict;
use warnings;
our($VERSION) = '$Rev$' =~ /(\d+)/;

&Janus::command_add({
	cmd => 'info',
	help => 'Provides information about janus',
	code => sub {
		my $nick = shift;
		&Janus::jmsg($nick, 
			'Janus is a server that allows IRC networks to share certain channels to other',
			'linked networks without needing to share all channels and make all users visible',
			'across both networks. If configured to allow it, users can also share their own',
			'channels across any linked network.',
			'-------------------------',
			'The source code can be found at http://danieldegraaf.afraid.org/janus/trunk/',
			'This file was checked out from $URL$',
			'If you make any modifications to this software, you must change these URLs',
			'to one which allows downloading the version of the code you are running.'
		);
	}
}, {
	cmd => 'modules',
	help => 'Version information on all modules loaded by janus',
	code => sub {
		my $nick = shift;
		my @mods = sort('main', keys %main::INC);
		my($m1, $m2) = (10,3); #min lengths
		my @mvs;
		for (@mods) {
			s/\.pmc?$//;
			s#/#::#g;
			no strict 'refs';
			my $v = ${$_.'::VERSION'} || '';
			next unless $v;
			$m1 = length $_ if $m1 < length $_;
			$m2 = length $v if $m2 < length $v;
			push @mvs, $_, $v;
		}
		my $ex = ' %-'.$m1.'s %'.$m2.'s';
		while (@mvs) {
			my @out = splice @mvs,0,6;
			&Janus::jmsg($nick, sprintf $ex x (@out/2), @out);
		}
	}
}, {
	cmd => 'renick',
	# hidden command, no help
	code => sub {
		my($nick,$name) = @_;
		return &Janus::jmsg($nick, "You must be an IRC operator to use this command") unless $nick->has_mode('oper');
		$Conffile::netconf{janus}{janus} = $name;
		&Janus::reload('Interface');
	},
}, {
	cmd => 'reload',
	help => "Load or reload a module, live. \002EXPERIMENTAL\002.",
	details => [
		"Syntax: \002RELOAD\002 module",
		"\002WARNING\002: Reloading core modules may introduce bugs because of persistance",
		"of old code by the perl interpreter"
	],
	code => sub {
		my($nick,$name) = @_;
		return &Janus::jmsg($nick, "You must be an IRC operator to use this command") unless $nick->has_mode('oper');
		return &Janus::jmsg($nick, "Invalid module name") unless $name =~ /^([0-9_A-Za-z:]+)$/;
		my $n = $1;
		if (&Janus::reload($n)) {
			&Janus::err_jmsg($nick, "Module reloaded");
		} else {
			&Janus::err_jmsg($nick, "Module load failed: $@");
		}
	},
});

1;
