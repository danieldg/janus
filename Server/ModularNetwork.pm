# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Server::ModularNetwork;
use Persist 'LocalNetwork';
use strict;
use warnings;

our($VERSION) = '$Rev$' =~ /(\d+)/;

my @modules   :Persist(modules);   # {module} => definition - List of active modules
my @meta      :Persist(meta);      # key => sub{} for METADATA command
my @fromirc   :Persist(fromirc);   # command => sub{} for IRC commands
my @act_hooks :Persist(act_hooks); # type => module => sub{} for Janus Action => output

my @txt2cmode :Persist(txt2cmode); # quick lookup hashes for translation in/out of janus
my @cmode2txt :Persist(cmode2txt);
my @txt2umode :Persist(txt2umode);
my @umode2txt :Persist(umode2txt);

sub module_add {
	my($net,$name) = @_;
	my $mod = $net->find_module($name) or do {
		$net->send($net->cmd2($Janus::interface, OPERNOTICE => 
			"Unknown module $name, janus may become desynced if it is used"));
		# TODO inspircd specific
		return;
	};
	return if $modules[$$net]{$name};
	$modules[$$net]{$name} = $mod;
	if ($mod->{cmode}) {
		for my $cm (keys %{$mod->{cmode}}) {
			my $txt = $mod->{cmode}{$cm};
			warn "Overriding mode $cm = $txt" if $cmode2txt[$$net]{$cm} || $txt2cmode[$$net]{$txt};
			$cmode2txt[$$net]{$cm} = $txt;
			$txt2cmode[$$net]{$txt} = $cm;
		}
	}
	if ($mod->{umode}) {
		for my $um (keys %{$mod->{umode}}) {
			my $txt = $mod->{umode}{$um};
			warn "Overriding umode $um = $txt" if $umode2txt[$$net]{$um} || $txt2umode[$$net]{$txt};
			$umode2txt[$$net]{$um} = $txt;
			$txt2umode[$$net]{$txt} = $um;
		}
	}
	if ($mod->{umode_hook}) {
		for my $txt (keys %{$mod->{umode}}) {
			warn "Overriding umode $txt" if $txt2umode[$$net]{$txt} && !$mod->{umode}{$txt2umode[$$net]{$txt}};
			$txt2umode[$$net]{$txt} = $mod->{umode_hook}{$txt};
		}
	}
	if ($mod->{cmds}) {
		for my $cmd (keys %{$mod->{cmds}}) {
			warn "Overriding command $cmd" if $fromirc[$$net]{$cmd};
			$fromirc[$$net]{$cmd} = $mod->{cmds}{$cmd};
		}
	}
	if ($mod->{acts}) {
		for my $t (keys %{$mod->{acts}}) {
			$act_hooks[$$net]{$t}{$name} = $mod->{acts}{$t};
		}
	}
	if ($mod->{metadata}) {
		for my $i (keys %{$mod->{metadata}}) {
			warn "Overriding metadata $i" if $meta[$$net]{$i};
			$meta[$$net]{$i} = $mod->{acts}{$i};
		}
	}
}

sub module_remove {
	my($net,$name) = @_;
	my $mod = delete $modules[$$net]{$name} or do {
		$net->send($net->cmd2($Janus::interface, OPERNOTICE => "Could not unload moule $name: not loaded"));
		return;
	};
	if ($mod->{cmode}) {
		for my $cm (keys %{$mod->{cmode}}) {
			my $txt = $mod->{cmode}{$cm};
			delete $cmode2txt[$$net]{$cm};
			delete $txt2cmode[$$net]{$txt};
		}
	}
	if ($mod->{umode}) {
		for my $um (keys %{$mod->{umode}}) {
			my $txt = $mod->{umode}{$um};
			delete $umode2txt[$$net]{$um};
			delete $txt2umode[$$net]{$txt};
		}
	}
	if ($mod->{umode_hook}) {
		for my $txt (keys %{$mod->{umode}}) {
			delete $txt2umode[$$net]{$txt};
		}
	}
	if ($mod->{cmds}) {
		for my $cmd (keys %{$mod->{cmds}}) {
			delete $fromirc[$$net]{$cmd};
		}
	}
	if ($mod->{acts}) {
		for my $t (keys %{$mod->{acts}}) {
			delete $act_hooks[$$net]{$t}{$name};
		}
	}
	if ($mod->{metadata}) {
		for my $i (keys %{$mod->{metadata}}) {
			delete $meta[$$net]{$i};
		}
	}
}

sub get_module {
	my($net,$name) = @_;
	$modules[$$net]{$name};
}

sub all_modules {
	my($net,$name) = @_;
	keys %{$modules[$$net]};
}

sub cmode2txt {
	my($net,$cm) = @_;
	$cmode2txt[$$net]{$cm};
}

sub txt2cmode {
	my($net,$tm) = @_;
	$txt2cmode[$$net]{$tm};
}

sub all_cmodes {
	my $net = shift;
	keys %{$txt2cmode[$$net]};
}

sub umode2txt {
	my($net,$cm) = @_;
	$umode2txt[$$net]{$cm};
}

sub txt2umode {
	my($net,$tm) = @_;
	$txt2umode[$$net]{$tm};
}

sub all_umodes {
	my $net = shift;
	keys %{$txt2umode[$$net]};
}

sub do_meta {
	my $net = shift;
	my $key = shift;
	my $mdh = $meta[$$net]{$key};
	return () unless $mdh;
	$mdh->($net, @_);
}

sub from_irc {
	my $net = $_[0];
	my $cmd = $_[2];
	$cmd = $fromirc[$$net]{$cmd} || $cmd;
	$cmd = $fromirc[$$net]{$cmd} || $cmd if $cmd && !ref $cmd; # allow one layer of indirection
	unless ($cmd && ref $cmd) {
		$net->send($net->cmd2($Janus::interface, OPERNOTICE => "Unknown command $cmd, janus is possibly desynced"));
		print "Unknown command '$cmd'\n";
		return ();
	}
	$cmd->(@_);
}

sub to_irc {
	my $net = shift;
	my @sendq;
	for my $act (@_) {
		if (ref $act && ref $act eq 'HASH') {
			my $type = $act->{type};
			next unless $act_hooks[$$net]{$type};
			for my $hook (values %{$act_hooks[$$net]{$type}}) {
				push @sendq, $hook->($net,$act);
			}
		} else {
			push @sendq, $act;
		}
	}
	@sendq;
}

for my $net (values %Janus::nets) {
	next unless $net->isa(__PACKAGE__);
	my @mods = keys %{$modules[$$net]};
	print "Reloading module definitions for $net\n";
	for my $mod (@mods) {
		$net->module_remove($mod);
		$net->module_add($mod);
	}
}

1;
