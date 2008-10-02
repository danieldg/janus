# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::Core;
use strict;
use warnings;
use integer;

$perl::VERSION = sprintf '%vd', $^V;

&Janus::command_add({
	cmd => 'about',
	help => 'Provides information about janus',
	code => sub {
		&Janus::jmsg($_[1], 
			'Janus is a server that allows IRC networks to share certain channels to other',
			'linked networks without needing to share all channels and make all users visible',
			'across both networks. If configured to allow it, users can also share their own',
			'channels across any linked network.',
			'The source code can be found at http://sourceforge.net/projects/janus-irc/',
		);
	}
}, {
	cmd => 'modules',
	help => 'Version information on all modules loaded by janus',
	details => [
		"Syntax: \002MODULES\002 [all|janus|other][columns]",
	],
	code => sub {
		my($src,$dst,$parm) = @_;
		$parm ||= 'a';
		my $w = $parm =~ /(\d+)/ ? $1 : 3;
		my @mods;
		if ($parm =~ /^j/) {
			@mods = sort('main', grep { $main::INC{$_} !~ /^\// } keys %main::INC);
		} elsif ($parm =~ /^o/) {
			@mods = sort('perl', grep { $main::INC{$_} =~ /^\// } keys %main::INC);
		} else {
			@mods = sort('main', 'perl', keys %main::INC);
		}
		my($m1, $m2) = (10,3); #min lengths
		my @mvs;
		for (@mods) {
			s/\.pmc?$//;
			s#/#::#g;
			my $v;
			if ($parm =~ /^s/i) {
				$v = $Janus::modinfo{$_} ? substr $Janus::modinfo{$_}{sha}, 0, 10 : '';
			} elsif ($Janus::modinfo{$_}) {
				$v = $Janus::modinfo{$_}{version};
			} else {
				no strict 'refs';
				$v = ${$_.'::VERSION'};
			}
			next unless $v;
			$m1 = length $_ if $m1 < length $_;
			$m2 = length $v if $m2 < length $v;
			push @mvs, [ $_, $v ];
		}
		my $c = 1 + $#mvs / $w;
		my $ex = ' %-'.$m1.'s %'.$m2.'s';
		for my $i (0..($c-1)) {
			&Janus::jmsg($dst, join '', map $_ ? sprintf $ex, @$_ : '', 
				map $mvs[$c*$_ + $i], 0 .. ($w-1));
		}
	}
}, {
	cmd => 'modinfo',
	help => 'Provides information about a module',
	details => [
		"Syntax: \002MODINFO\002 module",
	],
	code => sub {
		my($src,$dst,$mod) = @_;
		return &Janus::jmsg($dst, 'Module not loaded') unless $Janus::modinfo{$mod};
		my $ifo = $Janus::modinfo{$mod};
		my $active = $ifo->{active} ? 'active' : 'inactive';
		&Janus::jmsg($dst, "Module $mod is at version $ifo->{version}; hooks are $active",
			"Source checksum is $ifo->{sha}");
		&Janus::jmsg($dst, ' '.$ifo->{desc}) if $ifo->{desc};
		my(@hooks, @cmds);
		for my $cmd (sort keys %Event::commands) {
			next unless $Event::commands{$cmd}{class} eq $mod;
			push @cmds, $cmd;
		}
		for my $lvl (sort keys %Event::hook_mod) {
			next unless $Event::hook_mod{$lvl}{$mod};
			push @hooks, $lvl;
		}
		&Janus::jmsg($dst, 'Provides commands: '. join ' ', @cmds) if @cmds;
		&Janus::jmsg($dst, 'Hooks: '. join ' ', @hooks) if @hooks;
	},
}, {
	cmd => 'reload',
	help => "Load or reload a module, live.",
	details => [
		"Syntax: \002RELOAD\002 module",
		"\002WARNING\002: Reloading core modules may introduce bugs because of persistance",
		"of old code by the perl interpreter."
	],
	acl => 'admin',
	code => sub {
		my($src,$dst,$name) = @_;
		return &Janus::jmsg($dst, "Invalid module name") unless $name =~ /^([0-9_A-Za-z:]+)$/;
		my $n = $1;
		my $over = $Janus::modinfo{$n}{version} || 'none';
		if (&Janus::reload($n)) {
			my $ver = $Janus::modinfo{$n}{version} || 'unknown';
			&Log::audit("Module $n reloaded ($over => $ver) by " . $src->netnick);
			&Janus::jmsg($dst, "Module $n reloaded ($over => $ver)");
		} else {
			&Log::audit("Reload of module $n by ".$src->netnick.' failed');
			&Janus::jmsg($dst, "Module load failed");
		}
	},
}, {
	cmd => 'unload',
	help => "Unload the hooks registered by a module",
	acl => 'admin',
	code => sub {
		my($src,$dst,$name) = @_;
		if ($name !~ /::/ || $name eq __PACKAGE__) {
			&Janus::jmsg($dst, "You cannot unload the core module $name");
			return;
		}
		&Janus::unload($name);
		&Log::audit("Module $name unloaded by ".$src->netnick);
		&Janus::jmsg($dst, "Module $name unloaded");
	}
});

1;
