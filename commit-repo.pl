#!/usr/bin/env perl

use strict;
use warnings;
use v5.10;

use File::Basename;
use File::Copy "cp";
use Cwd;

use Getopt::Std;
$Getopt::Std::STANDARD_HELP_VERSION = 1;

my $progname = basename($0);
my $pwd = getcwd;

sub HELPMESSAGE {
	print <<EOF
This tool should be executed in a standard repostiroy path
it will scan the current directory to figure out the
CARCH and repository name, and will search for the main
repositories in ../../../<repo>/os/<CARCH>/
EOF
;
	print "usage: $progname [options]\n";
	print "options:\n";
	print <<EOF
  -d    dry run, do not commit any files
EOF
;
}

our ($opt_d);
getopts('d');


if (not ($pwd =~ m@/(?<from_repo>\w+)/os/(?<carch>x86_64|i686)$@)) {
	print("Failed to figure out the repository name and architecture\n");
	print("from the current path: " . $pwd);
	exit(1);
}

my $repo  = $+{from_repo};
my $carch = $+{carch};
my $db    = "${repo}.db";
#my $workdir = tempdir(CLEANUP => 1);

sub add_pkg($$) {
	my ($name, $array) = @_;

	if ($name =~ m@^(?<name>.*?)-(?<ver>\d.*)$@) {
		my %arr = (name => $+{name}, ver => $+{ver});
		push @$array, \%arr;
	}
}

sub read_db($) {
	my ($db) = @_;
	my @pkgarray;
	open(my $p, '-|', 'tar', '-tf', $db) or die "failed to read database for package list";
	while (<$p>) {
		next unless m@/$@;
		s@/$@@;
		add_pkg($_, \@pkgarray);
	}
	close($p);
	return \@pkgarray;
}

sub load_repos() {
	my %repos;

	for my $r (qw/core extra community multilib linux devel/) {
		my $fromdb = "../../../$r/os/$carch/${r}.db.tar.gz";
		next unless -e $fromdb;

		my $targpkgs = read_db $fromdb;
		next if 0 == scalar(@$targpkgs);
		$repos{$r} = $targpkgs;
	}

	return %repos;
}


printf("Committing from $repo ($carch)\n");

my $new_packages = read_db $db;

if (scalar(@$new_packages) == 0) {
	print("No packages in $db\n");
	exit(0);
}

my %repos = load_repos;

sub remember_repo($$) {
	my ($name, $repo) = @_;

	my $remember;
	unless (open $remember, '>', ".repo.for.$name") {
		print("warning: cannot remember repository choice\n");
		return;
	}
	print {$remember} "$repo\n";
	close $remember;
}

sub repo_chosen($) {
	my ($name) = @_;
	my $f;
	return undef
	  unless (open $f, '<', ".repo.for.$name");
	my $line = <$f>;
	close($f);
	chomp $line;
	if (exists($repos{$line})) {
		print "Remembered repo for $name: $line\n";
		return $line;
	}
	return undef;
}

sub set_repo_for($) {
	my ($pkg) = @_;
	my $pkgname = ${$pkg}{name};
	my $found = repo_chosen $pkgname;
	if (!defined($found)) {
		keys %repos;
		OUTER:
		while ( my ($repo, $pkgs) = each %repos ) {
			for my $pkgref (@$pkgs) {
				if ($pkgname eq ${$pkgref}{name}) {
					if (defined($found)) {
						print("WARNING: $pkgname exists in multiple repositories!\n");
						$found = undef;
						last OUTER;
					}
					$found = $repo;
				}
			}
		}
	}

	${$pkg}{repo} = $found;

	if (!defined(${$pkg}{repo})) {
		my $answer;
		print("Choose repository for $pkgname: ");
		$| = 1;
		QUESTION:
		while (defined($answer = <>)) {
			chomp($answer);
			if (exists($repos{$answer})) {
				${$pkg}{repo} = $repo;
				remember_repo $pkgname, $answer;
				last QUESTION;
			}
			print("Repository '$answer' has not been found previously!\n");
			print("Choose repository for $pkgname: ");
		}
		if (!defined(${$pkg}{repo})) {
			exit(1);
		}
	}
}

my $err = 0;
print("*** checking files...\n");
for my $pkg (@$new_packages) {
	my $name = ${$pkg}{name};
	my $ver  = ${$pkg}{ver};
	my $tar  = "$name-$ver-$carch.pkg.tar.xz";
    # check for a signature file:
    if (not -e $tar) {
		$tar = "$name-$ver-any.pkg.tar.xz";
	}
    if (not -e $tar) {
    	print("Package archive missing for $name-$ver\n");
    	$err = 1;
    }
	my $sig = "$tar.sig";
    if (not -e $sig) {
    	print("Signature missing for $name-$ver\n");
    	$err = 1;
    }
    ${$pkg}{tar} = $tar;
    ${$pkg}{sig} = $sig;
}
die "There have been errors\n" if $err;

print("*** finding target repositories...\n");
for my $pkg (@$new_packages) {
	set_repo_for($pkg);
}

# First copy all the files
my %tarlist;
print("*** copying files...\n");
for my $pkg (@$new_packages) {
	my $name   = ${$pkg}{name};
	my $ver    = ${$pkg}{ver};
	my $target = ${$pkg}{repo};
	my $tar    = ${$pkg}{tar};
	my $sig    = ${$pkg}{sig};
	my $dest = "../../../$target/os/$carch";
	if (!$opt_d) {
		print ("copying: $tar -> $dest/$tar\n");
		cp $tar, "$dest/$tar" or die "Copying $tar to destination failed: $!";
		print ("copying: $sig -> $dest/$sig\n");
		cp $sig, "$dest/$sig" or die "Copying $sig to destination failed: $!";
	} else {
		print ("NOT copying: $tar -> $dest/$tar\n");
		print ("NOT copying: $sig -> $dest/$sig\n");
	}
	if (exists($tarlist{$target})) {
		push @{$tarlist{$target}}, $tar;
	} else {
		$tarlist{$target} = [$tar];
	}
}

# Then repo-add them in bulks
print("*** adding packages...\n");
while (my ($repo, $files) = each %tarlist) {
	chdir ("../../../$repo/os/$carch") or die "failed to change directory to ../../../$repo/os/$carch/";
	if (!$opt_d) {
		print("Committing to $repo: ", join(", ", @$files), "\n");
		if (system('repo-add', '-f', "$repo.db.tar.gz", @$files) != 0) {
			die("Failed to commit packages to $repo");
		}
	} else {
		print("NOT committing to $repo: ", join(", ", @$files), "\n");
	}
	chdir $pwd;
}

# Remove old files
print("*** cleaning up...\n");
for my $pkg (@$new_packages) {
	my $name   = ${$pkg}{name};
	my $ver    = ${$pkg}{ver};
	my $target = ${$pkg}{repo};
	my $tar    = ${$pkg}{tar};
	my $sig    = ${$pkg}{sig};
	my $dest = "../../../$target/os/$carch";
	chdir $dest;
	my @files = <${name}-[0-9]*.pkg.tar.xz>;
	for my $old (@files) {
		next if $old eq $tar;
		if (!$opt_d) {
			print("Deleting old files: $old $old.sig\n");
			unlink($old) or print("Failed to remove $old");
			unlink("${old}.sig") or print("Failed to remove ${old}.sig");
		} else {
			print("NOT deleting old files: $old $old.sig\n");
		}
	}
	chdir $pwd;
}

if (!$opt_d) {
	print("Removing repository choice temp files...\n");
	unlink <.repo.for.*> or print("Failed to remove .repo.for.* files\n");
} else {
	print("Keeping repository choices.\n");
}
