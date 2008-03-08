# Copyright (C) 2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Debug;
use strict;
use warnings;

our($init, $IO, $alloc, $info, $warn);

unless ($init) {
	($init, $IO, $alloc, $info, $warn) = (1,1,1,1,1);
}

sub netin {
	return unless $IO;
	my($net, $line) = @_;
	my $name = 
		$net->can('name') ? $net->name() : 
		$net->can('id') ? $net->id() : $$net;
	print "\e[32m    IN\@$name $line\e[0m\n";
}

sub netout {
	return unless $IO;
	my($net, $line) = @_;
	my $name = 
		$net->can('name') ? $net->name() : 
		$net->can('id') ? $net->id() : $$net;
	print "\e[34m   OUT\@$name $line\e[0m\n";
}

sub warn_in {
	return unless $warn;
	my($src, $msg) = @_;
	my $name = $EventDump::INST->ijstr($src);
	print "\e[35m \@$name $msg\e[m\n";
}

sub err_in {
	my($src, $msg) = @_;
	my $name = $EventDump::INST->ijstr($src);
	print "\e[31m \@$name $msg\e[m\n";
}

sub err {
	print "\e[31mERR: $_[0]\e[m\n";
}

sub alloc {
	return unless $alloc;
	print " $_[0]\n";
}

sub info {
	return unless $info;
	print " $_[0]\n";
}

1;
