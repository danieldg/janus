# Copyright (C) 2007-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::Core;
use strict;
use warnings;
use integer;

$perl::VERSION = sprintf '%vd', $^V;

my %help_section = (
	Account => 'Account managment',
	Admin => 'Administration',
	Channel => 'Channel managment',
	Info => 'Information',
	Network => 'Network managment',
	Other => 'Other',
);

Event::command_add({
	cmd => 'about',
	help => 'Provides information about janus',
	section => 'Info',
	code => sub {
		Janus::jmsg($_[1],
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
	section => 'Info',
	syntax => '[all|janus|other|sha][columns]',
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
			push @mvs, [ $_, $v ];
		}
		Interface::msgtable($dst, \@mvs, cols => $w, fmtfmt => [ '%%-%ds', '%%%ds' ]);
	}
}, {
	cmd => 'modinfo',
	help => 'Provides information about a module',
	section => 'Info',
	syntax => '<module>',
	code => sub {
		my($src,$dst,$mod) = @_;
		return Janus::jmsg($dst, 'Module not loaded') unless $Janus::modinfo{$mod};
		my $ifo = $Janus::modinfo{$mod};
		my $active = $ifo->{active} ? 'active' : 'inactive';
		Janus::jmsg($dst, "Module $mod is at version $ifo->{version}; hooks are $active",
			"Source checksum is $ifo->{sha}");
		Janus::jmsg($dst, ' '.$ifo->{desc}) if $ifo->{desc};
		my(@hooks, @cmds, @sets);
		for my $cmd (sort keys %Event::commands) {
			next unless $Event::commands{$cmd}{class} eq $mod;
			push @cmds, $cmd;
		}
		for my $set (sort keys %Event::settings) {
			next unless $Event::settings{$set}{class} eq $mod;
			push @sets, $set;
		}
		for my $lvl (sort keys %Event::hook_mod) {
			next unless $Event::hook_mod{$lvl}{$mod};
			push @hooks, $lvl;
		}
		Janus::jmsg($dst, 'Provides commands: '. join ' ', @cmds) if @cmds;
		Janus::jmsg($dst, 'Provides settings: '. join ' ', @sets) if @sets;
		Janus::jmsg($dst, 'Hooks: '. join ' ', @hooks) if @hooks;
	},
}, {
	cmd => 'reload',
	help => "Load or reload a module, live.",
	section => 'Admin',
	syntax => '<module>',
	details => [
		"\002WARNING\002: Reloading core modules may introduce bugs because of persistance",
		"of old code by the perl interpreter."
	],
	acl => 'reload',
	code => sub {
		my($src,$dst,$name) = @_;
		return Janus::jmsg($dst, "Invalid module name") unless $name =~ /^([0-9_A-Za-z:]+)$/;
		my $n = $1;
		my $over = $Janus::modinfo{$n}{version} || 'none';
		if (Janus::reload($n)) {
			my $ver = $Janus::modinfo{$n}{version} || 'unknown';
			Log::audit("Module $n reloaded ($over => $ver) by " . $src->netnick);
			Janus::jmsg($dst, "Module $n reloaded ($over => $ver)");
		} else {
			Log::audit("Reload of module $n by ".$src->netnick.' failed');
			Janus::jmsg($dst, "Module load failed");
		}
	},
}, {
	cmd => 'unload',
	help => "Unload the hooks registered by a module",
	section => 'Admin',
	syntax => '<module>',
	acl => 'unload',
	code => sub {
		my($src,$dst,$name) = @_;
		if ($name !~ /::/ || $name eq __PACKAGE__) {
			Janus::jmsg($dst, "You cannot unload the core module $name");
			return;
		}
		Janus::unload($name);
		Log::audit("Module $name unloaded by ".$src->netnick);
		Janus::jmsg($dst, "Module $name unloaded");
	}
}, {
	cmd => 'help',
	help => 'Help on janus commands. See "help help" for use.',
	section => 'Info',
	api => '=src =replyto ?$',
	syntax => "[<command>|\002ALL\002]",
	code => sub {
		my($src,$dst,$item) = @_;
		$item = lc $item || '';
		if (exists $Event::commands{lc $item}) {
			my $det = $Event::commands{$item}{details};
			my $syn = $Event::commands{$item}{syntax};
			my $help = $Event::commands{$item}{help};
			Janus::jmsg($dst, "Syntax: \002".uc($item)."\002 $syn") if $syn;
			if (ref $det) {
				Janus::jmsg($dst, @$det);
			} elsif ($syn || $help) {
				Janus::jmsg($dst, $help) if $help;
			} else {
				Janus::jmsg($dst, 'No help exists for that command');
			}
			my $acl = $Event::commands{$item}{acl};
			if ($acl) {
				$acl = 'oper' if $acl eq '1';
				my $allow = Account::acl_check($src, $acl) ? 'you' : 'you do not';
				Janus::jmsg($dst, "Requires access to '$acl' ($allow currently have access)");
			}
			my $aclchk = $Event::commands{$item}{aclchk};
			if ($aclchk) {
				my $allow = Account::acl_check($src, $aclchk) ? 'you' : 'you do not';
				Janus::jmsg($dst, "Some options may require access to '$aclchk' ($allow currently have access)");
			}
		} elsif ($item eq '' || $item eq 'all') {
			my %cmds;
			my $synlen = 0;
			for my $cmd (sort keys %Event::commands) {
				my $h = $Event::commands{$cmd}{help};
				my $acl = $Event::commands{$cmd}{acl};
				next unless $h;
				if ($acl && $item ne 'all') {
					$acl = 'oper' if $acl eq '1';
					next unless Account::acl_check($src, $acl);
				}
				my $section = $Event::commands{$cmd}{section} || 'Other';
				$cmds{$section} ||= [];
				push @{$cmds{$section}}, $cmd;
				$synlen = length $cmd if length $cmd > $synlen;
			}
			Janus::jmsg($dst, "Use '\002HELP\002 command' for details");
			for my $section (sort keys %cmds) {
				my $sname = $help_section{$section} || $section;
				Janus::jmsg($dst, $sname.':', map {
					sprintf " \002\%-${synlen}s\002  \%s", uc $_, $Event::commands{$_}{help};
				} @{$cmds{$section}});
			}
		} else {
			Janus::jmsg($dst, "Command not found. Use '\002HELP\002' to see the list of commands");
		}
	}
});

1;
