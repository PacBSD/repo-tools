#!/usr/bin/env perl

# This script requires vercmp from pacman in PATH

use strict;
use warnings;
use v5.10;
use autodie;

use File::Basename;
use Cwd;
use Getopt::Std;

use JSON qw( decode_json );

my $progname = basename($0);

$Getopt::Std::STANDARD_HELP_VERSION = 1;
sub HELPMESSAGE {
	print "usage: $progname [options] DBFILE\n";
	print <<EOF
options:
  -q   suppress some output
  -d   add --try to the pkgdepdb commandline
  -r   reinstall same-version packages
EOF
;
}

our ($opt_q, $opt_d, $opt_h, $opt_r);
getopts('qdhr');

if ($opt_h) {
	HELPMESSAGE;
	exit 0;
}

if (scalar(@ARGV) > 1) {
	HELPMESSAGE;
	exit 1;
}

my @depdb_params;
if (scalar(@ARGV) == 1) {
	@depdb_params = ( 'pkgdepdb', '--db', $ARGV[0], '--json=query' );
} else {
	@depdb_params = ( 'pkgdepdb', '--json=query' );
}

# Part 1: check for dups (this should have happened already)

my %packages;

sub vercmp($$) {
	my $p;
	open $p, '-|', 'vercmp', @_;
	my $res= <$p>;
	close($p);
	die "vercmp failed with status $?" if ($?);
	return $res;
}

for my $file (<*.pkg.tar.xz>) {
	# Since we're nice, let's warn about missing sigs now, eh?
	print "WARNING: missing signature for $file\n" unless $opt_q or -e "${file}.sig";

	# get the name
	#if (not($file =~ m@^(?<name>.*?(?=-\d))-(?<version>\d[^-]*-\d[^-]*)-(?:x86_64|i686|any)\.pkg\.tar\.xz$@)) {
	if (not($file =~ m@^(?<name>.*)-(?<version>[^-]+-\d[^-]*)-(?:x86_64|i686|any)\.pkg\.tar\.xz$@)) {
		print "WARNING: archive not recognized as a package: $file\n";
		next;
	}

	my $name = $+{name};
	my $ver  = $+{version};
	if (exists($packages{$name})) {
		print "WARNING: duplicate package found: $name\n";
		# use the newer one...
		next if vercmp(${$packages{$name}}{ver}, $ver) > 0;
	}
	$packages{$name} = {name => $+{name}, ver => $+{version}, tar => $file};
}

# Part 2: read the pkgdepdb...

open my $pdb, '-|', @depdb_params, '--quiet', '-P';
my $installed_json = do { local $/; <$pdb> };
close $pdb;
die "pkgdepdb failed with status $?" if ($?);
my $pdb_installed = decode_json($installed_json);

my $installed = ${$pdb_installed}{packages};

for my $pkghash (@$installed) {
	my $name = ${$pkghash}{name};

	next unless exists($packages{$name});

	# this package exists; check the version
	my $existing = $packages{$name};
	my $dbver = ${$pkghash}{version};
	my $flver = ${$existing}{ver};
	my $cmp = vercmp($dbver, $flver);
	if ($cmp > 0) {
		# existing is newer
		print("A newer version of $name is already in place: $dbver (found version $flver)\n");
		delete $packages{$name};
	}
	elsif ($cmp == 0) {
		if ($opt_r) {
			print("Reinstalling $name version $dbver\n") unless $opt_q;
			next;
		}
		# without -r we don't reinstall
		delete $packages{$name};
	}
	else {
		# existing one is older, this is fine
		print("Upgrading $name from $dbver to $flver\n") unless $opt_q;
	}
}

my @tarlist;
keys %packages;
while (my ($name, $pkg) = each %packages) {
	push @tarlist, ${$pkg}{tar};
}

if (scalar(keys %packages) == 0) {
	print("No packages to upgrade\n") unless $opt_q;
	exit 0;
}

if ($opt_d) {
	exec @depdb_params, '--dry', '-i', @tarlist;
} else {
	exec @depdb_params, '-i', @tarlist;
}
