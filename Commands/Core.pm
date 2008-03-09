# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::Core;
use strict;
use warnings;
use integer;

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
			'The source code can be found at http://sourceforge.net/projects/janus-irc/',
			'If you make any modifications to this software, you must change this URL',
			'to one which allows downloading the version of the code you are running.'
		);
	}
}, {
	cmd => 'modules',
	help => 'Version information on all modules loaded by janus',
	details => [
		"Syntax: \002MODULES\002 [all|janus|other] [columns]",
	],
	code => sub {
		my($nick,$parm) = @_;
		$parm ||= 'a';
		my $w = $parm =~ /(\d)/ ? $1 : 3;
		my @mods;
		if ($parm =~ /^j/) {
			@mods = sort 'main', grep ref $main::INC{$_}, keys %main::INC;
		} elsif ($parm =~ /^o/) {
			@mods = sort grep !ref $main::INC{$_}, keys %main::INC;
		} else {
			@mods = sort('main', keys %main::INC);
		}
		my($m1, $m2) = (10,3); #min lengths
		my @mvs;
		for (@mods) {
			s/\.pmc?$//;
			s#/#::#g;
			no strict 'refs';
			my $v = ${$_.'::VERSION_NAME'} || ${$_.'::VERSION'} || '';
			next unless $v;
			$m1 = length $_ if $m1 < length $_;
			$m2 = length $v if $m2 < length $v;
			push @mvs, [ $_, $v ];
		}
		my $c = 1 + $#mvs / $w;
		my $ex = ' %-'.$m1.'s %'.$m2.'s';
		for my $i (0..($c-1)) {
			&Janus::jmsg($nick, join '', map $_ ? sprintf $ex, @$_ : '', 
				map $mvs[$c*$_ + $i], 0 .. ($w-1));
		}
	}
}, {
	cmd => 'reload',
	help => "Load or reload a module, live.",
	details => [
		"Syntax: \002RELOAD\002 module",
		"\002WARNING\002: Reloading core modules may introduce bugs because of persistance",
		"of old code by the perl interpreter."
	],
	acl => 1,
	code => sub {
		my($nick,$name) = @_;
		return &Janus::jmsg($nick, "Invalid module name") unless $name =~ /^([0-9_A-Za-z:]+)$/;
		my $n = $1;
		if (&Janus::reload($n)) {
			&Janus::jmsg($nick, "Module $n reloaded");
		} else {
			my $err = $@ || $!;
			$err =~ s/\n/ /g;
			&Janus::err_jmsg($nick, "Module load failed: $err");
		}
	},
}, {
	cmd => 'unload',
	help => "Unload the hooks registered by a module",
	acl => 1,
	code => sub {
		my($nick,$name) = @_;
		if ($name !~ /::/ || $name eq __PACKAGE__) {
			&Janus::jmsg($nick, "You cannot unload the core module $name");
			return;
		}
		&Janus::unload($name);
		&Janus::jmsg($nick, "Module $name unloaded");
	}
});

1;
