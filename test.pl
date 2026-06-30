#!/usr/bin/env perl

use v5.36;
use strict;
use warnings;
use File::Spec;
use feature 'say';
use feature 'defer';
no warnings 'experimental';

sub list_directory_entries($directory_path) {
    opendir my $dir, $directory_path
      or die "Couldn't open directory '$directory_path': $!";

    my @entries = grep { $_ ne q{.} && $_ ne q{..} } readdir $dir;
    closedir $dir or die "Couldn't close directory '$directory_path': $!";

    return @entries;
}

sub run_quietly(@command) {
    my $pid = fork();
    die "Couldn't fork for '@command': $!" if !defined $pid;

    if ($pid == 0) {
        open STDOUT, q{>}, File::Spec->devnull()
          or die "Couldn't redirect STDOUT: $!";
        open STDERR, q{>}, File::Spec->devnull()
          or die "Couldn't redirect STDERR: $!";

        exec { $command[0] } @command
          or die "Couldn't exec '@command': $!";
    }

    waitpid $pid, 0;
    return $?;
}

sub find_single_program($program_directory) {
    my @programs =
      sort grep { -f File::Spec->catfile($program_directory, $_) }
      list_directory_entries($program_directory);

    die "'$program_directory' is empty.\n" if !@programs;

    if (@programs > 1) {
        die "More than one file in '$program_directory': @programs\n"
          . "Please solve the ambiguity.\n";
    }

    return File::Spec->catfile($program_directory, $programs[0]);
}

sub test_files($tests_directory) {
    return map { File::Spec->catfile($tests_directory, $_) }
      sort grep { -f File::Spec->catfile($tests_directory, $_) }
      list_directory_entries($tests_directory);
}

my $program_directory = File::Spec->catdir(q{.}, q{zig-out}, q{bin});
my $tests_directory   = File::Spec->catdir(q{.}, q{tests});

my $build_exit_code = run_quietly(q{zig}, q{build});
if ($build_exit_code != 0) {
    die "Build failed with exit code $build_exit_code.\n";
}

my $program      = find_single_program($program_directory);
my @failed_tests = ();

my @tests = test_files($tests_directory);

for my $test_file (@tests) {
    my $exit_code = run_quietly($program, q{-f}, $test_file);
    if ($exit_code != 0) {
        push @failed_tests, [$test_file, $exit_code];
    }
}

defer {
    my $total = scalar(@tests);
    my $failed = scalar(@failed_tests);
    my $succeeded = $total - $failed;
    say "SUCCESS: $succeeded; FAILED: $failed; TOTAL: $total;"
};

if (@failed_tests) {
    print STDERR "Failed tests:\n";
    for my $failure (@failed_tests) {
        my ($test_file, $exit_code) = @{$failure};
        print STDERR "  $test_file (exit code $exit_code)\n";
    }
    exit 1;
}

exit 0;
