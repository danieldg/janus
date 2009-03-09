# Copyright (C) 2007-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::Upgrade;
use strict;
use warnings;
use Util::Exec;
use Scalar::Util qw(weaken);

sub upgrade {
	my($dst,$force) = @_;
	my @mods = sort keys %Janus::modinfo;
	my @done;
	for my $mod (@mods) {
		next unless $Janus::modinfo{$mod}{active} || $Janus::modinfo{$mod}{retry};
		unless ($force) {
			my $old_sha = $Janus::modinfo{$mod}{sha};
			Janus::csum_read($mod);
			next if $old_sha eq $Janus::modinfo{$mod}{sha};
		}
		if (Janus::reload($mod)) {
			delete $Janus::modinfo{$mod}{retry};
			push @done, $mod;
		} else {
			$Janus::modinfo{$mod}{retry} = 1;
			push @done, "\00304$mod\017";
		}
	}
	Log::info('Upgrade finished');
	Janus::jmsg($dst, join ' ', 'Modules reloaded:', sort @done);
}

Event::command_add({
	cmd => 'upgrade',
	help => 'Upgrades all modules loaded by janus',
	syntax => '[force]',
	section => 'Admin',
	acl => 'upgrade',
	code => sub {
		my($src,$dst,$arg) = @_;
		my $force = ($arg && $arg eq 'force');
		Log::audit(($force ? 'Full module reload' : 'Upgrade') .
			' started by '.$src->netnick);
		upgrade($dst,$force);
	},
}, {
	cmd => 'up-tar',
	help => 'Downloads and extracts an updated version of janus via gitweb',
	section => 'Admin',
	acl => 'up-tar',
	code => sub {
		my($src,$dst) = @_;
		Log::audit('Up-tar started by '.$src->netnick);
		my $final = {
			code => sub {
				my $dst = $_[0]->{dst} or return;
				if ($?) {
					Janus::jmsg($dst, 'Execution falied, see daemon.log for details');
				} else {
					upgrade($dst, 0);
				}
			},
			dst => $dst,
		};
		weaken($final->{dst});
		Util::Exec::bgrun(sub {
			system 'wget --output-document janus.tgz http://github.com/danieldg/janus/tarball/master' and return 1;
			system 'tar --extract --gzip --strip 1 --file janus.tgz' and return 1;
			return 0;
		}, $final) or Janus::jmsg($dst, 'Failed to fork');
	}
}, {
	cmd => 'up-git',
	help => 'Runs "git pull"',
	section => 'Admin',
	acl => 'up-git',
	code => sub {
		my($src,$dst) = @_;
		Log::audit('Up-git started by '.$src->netnick);
		my $final = {
			code => sub {
				my $dst = $_[0]->{dst} or return;
				if ($?) {
					Janus::jmsg($dst, 'Execution falied, see daemon.log for details');
				} else {
					upgrade($dst, 0);
				}
			},
			dst => $dst,
		};
		weaken($final->{dst});
		Util::Exec::bgrun(sub {
			system 'git pull' and return 1;
			return 0;
		}, $final) or Janus::jmsg($dst, 'Failed to fork');
	}
});

1;
