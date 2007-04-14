package JConf;
use strict;
use warnings;
use Unreal;
use IO::Select;

sub new {
	my $class = shift;
	my %arr = (
		file => shift || 'janus.conf',
		nets => {},
		readers => IO::Select->new(),
	);
	bless \%arr, $class;
}

sub rehash {
	my $cfg = shift;
	local $_;
	my $net;
	open my $conf, $cfg->{file};
	$conf->untaint(); 
		# the configurator is assumed to have at least half a brain :)
	while (<$conf>) {
		chomp;
		s/\s*$//;
		next if /^\s*(#|$)/;
		s/^\s*(\S+)\s*// or do {
			print "Error in line $. of config file\n";
			next;
		};
		my $type = lc $1;

		if ($type eq 'unreal') {
			if (defined $net) {
				print "Missing closing brace at line $. of config file\n";
			}
			/^(\S+)/ or do {
				print "Error in line $. of config file: expected network ID\n";
				next;
			};
			my $netid = $1;
			$net = $cfg->{nets}->{$netid};
			unless (defined $net && $net->isa('Unreal')) {
				print "Creating new net $netid\n";
				$cfg->{nets}->{$netid} = $net = Unreal->new(id => $netid);
			}
		} elsif ($type eq '}') {
			unless (defined $net) {
				print "Extra closing brace at line $. of config file\n";
				next;
			}
			unless (exists $Janus::nets{$net->id()}) {
				print "Connecting to $net->{netname}\n";
				if ($net->connect()) {
					Janus::link($net);
					$cfg->{readers}->add([$net->{sock}, '', $net]);
				} else {
					print "Cannot connect to $net->{id}\n";
				}
			}
			$net = undef;
		} elsif ($type eq '{') {
		} else {
			unless (defined $net) {
				print "Error in line $. of config file: not in a network definition\n";
				next;
			}
			if (ref $net->{$type}) {
				print "Error in line $. of config file: $type is not a valid config item for this network\n";
				next;
			}
			$net->{$type} = $_;
		}
	}
	close $conf;
}

sub modload {
 my $class = shift;
 Janus::hook_add($class,
	REHASH => act => sub {
		my $act = shift;
		$Janus::conf->rehash();
	}, LINKED => act => sub {
		my $act = shift;
		my $net = $act->{net};
		if ($net->id() eq 't1') {
			Janus::insert_full(+{
				type => 'LINKREQ',
				net => $net,
				dst => $Janus::nets{t2},
				slink => '#opers',
				dlink => '#test',
			});
		} elsif ($net->id() eq 't2') {
			Janus::insert_full(+{
				type => 'LINKREQ',
				net => $net,
				dst => $Janus::nets{t1},
				slink => '#test',
				dlink => '#opers',
			});
		} 
	});
}

1;
