# Copyright (C) 2007-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Util::ModularNetwork;
use Persist 'LocalNetwork';
use strict;
use warnings;

our @modules;   # {module} => definition - List of active modules
our @hooks;     # {'hook item'} => [ list ]
Persist::register_vars(qw(modules hooks));

sub module_add {
	my($net,$name,$opt) = @_;
	return if $modules[$$net]{$name};
	$hooks[$$net] = {}; # clear cache, will be rebuilt as needed
	my $mod;
	Event::named_hook('Server/find_module', $net, $name, \$mod);
	unless ($mod) {
		Log::err_in($net, "Unknown module $name, janus may become desynced if it is used") unless $opt;
		$mod = {};
	};
	$modules[$$net]{$name} = $mod;
	if ($mod->{cmode}) {
		for my $cm (keys %{$mod->{cmode}}) {
			my $ltxt = $mod->{cmode}{$cm};
			my($t, $txt) = $ltxt =~ /^(.)_(.+)$/ or do {
				warn "Use of ltxt=$ltxt for cm=$cm is deprecated in $name"; next;
			};
			if ($t eq 'r') {
				$mod->{cmode_in}{$cm} = sub {
					my(undef, $di, undef, $ai, $mo, $ao, $do) = @_;
					push @$mo, $txt;
					push @$ao, 1;
					push @$do, $di;
				};
				$mod->{cmode_out}{$txt} = sub {
					($cm)
				};
			} elsif ($t eq 'v' || $t eq 'l') {
				$mod->{cmode_in}{$cm} = sub {
					my(undef, $di, undef, $ai, $mo, $ao, $do) = @_;
					push @$mo, $txt;
					push @$ao, shift @$ai;
					push @$do, $di;
				};
				$mod->{cmode_out}{$txt} = sub {
					($cm, $_[3])
				};
			} elsif ($t eq 's') {
				$mod->{cmode_in}{$cm} = sub {
					my(undef, $di, $ci, $ai, $mo, $ao, $do) = @_;
					push @$mo, $txt;
					push @$ao, $di eq '+' ? shift @$ai : $ci->get_mode($txt);
					push @$do, $di;
				};
				$mod->{cmode_out}{$txt} = sub {
					($cm, $_[4] eq '+' ? $_[3] : ())
				};
			} elsif ($t eq 'n') {
				$mod->{cmode_in}{$cm} = sub {
					my($ni, $di, undef, $ai, $mo, $ao, $do) = @_;
					push @$mo, $txt;
					push @$ao, $ni->nick(shift @$ai);
					push @$do, $di;
				};
				$mod->{cmode_out}{$txt} = sub {
					($cm, $_[3])
				};
			} 
		}
	}
	if ($mod->{umode}) {
		for my $um (keys %{$mod->{umode}}) {
			my $txt = $mod->{umode}{$um};
			$mod->{umode_in}{$um} = sub { $txt };
			$mod->{umode_out}{$txt} = sub { $um } if $txt;
		}
	}
}

sub module_remove {
	my($net,$name,$opt) = @_;
	my $mod = delete $modules[$$net]{$name} or do {
		return if $opt;
		Log::err_in($net, "Could not unload moule $name: not loaded");
		return;
	};
	$hooks[$$net] = {}; # clear cache, will be rebuilt as needed
}

sub all_modules {
	my($net,$name) = @_;
	keys %{$modules[$$net]};
}

sub reload_moddef {
	my $net = shift;
	return unless $net->isa(__PACKAGE__);
	my @mods = keys %{$modules[$$net]};
	Log::info('Reloading module definitions for',$net->name,$net->gid);
	for my $mod (@mods) {
		$net->module_remove($mod);
		$net->module_add($mod, 1);
	}
}

sub hook {
	my($net, $type, $level) = @_;
	my $key = $type.' '.$level;
	my $hk = $hooks[$$net]{$key};
	return @$hk if $hk;
	$hk = $hooks[$$net]{$key} = [];
	for my $mod (values %{$modules[$$net]}) {
		my $item = $mod->{$type}{$level};
		push @$hk, $item if $item;
	}
	@$hk;
}

Event::hook_add(
	MODRELOAD => 'act:1' => sub {
		my $act = shift;
		return unless $act->{module} =~ /^Server::/;
		for my $net (values %Janus::nets) {
			next unless $net->isa(__PACKAGE__);
			$net->reload_moddef();
		}
	}
);

1;
