package Test::Which;

use strict;
use warnings;

our $VERSION = '0.02';

use parent 'Exporter';
our @ISA = qw(Exporter);

use File::Which qw(which);
use IPC::Run3 qw(run3);
use version ();	# provide version->parse
use Test::Builder;

our @EXPORT_OK = qw(which_ok);
our %EXPORT_TAGS = ( all => \@EXPORT_OK );

my $TEST = Test::Builder->new();

=head1 NAME

Test::Which - Skip tests if external programs are missing from PATH (with version checks)

=head1 SYNOPSIS

  use Test::Which 'ffmpeg' => '>=6.0', 'convert' => '>=7.1';

  # At runtime in a subtest or test body
  use Test::Which qw(which_ok);

  subtest 'needs ffmpeg' => sub {
	  which_ok 'ffmpeg' => '>=6.0' or return;
	  ... # tests that use ffmpeg
  };

=head1 DESCRIPTION

Test::Which mirrors L<Test::Needs> but checks for executables in PATH.
It can also check simple version constraints using a built-in heuristic (tries --version, -version, -v, -V and extracts a dotted-number).
If a version is requested but cannot be determined, the requirement fails.

=head1 FUNCTIONS

=head2 which_ok @programs_or_pairs

Checks the named programs (with optional version constraints).
If any requirement is not met the current test or subtest is skipped via L<Test::Builder>.

=cut

# runtime function, returns true if all present & satisfy versions, otherwise calls skip
sub which_ok {
	my (@args) = @_;

	my $res = _check_requirements(@args);
	my @missing = @{ $res->{missing} };
	my @bad = @{ $res->{bad_version} };

	if (@missing || @bad) {
		my @msgs;
		push @msgs, map { "Missing required program '$_'" } @missing;
		push @msgs, map { "Version issue for $_->{name}: $_->{reason}" } @bad;
		my $msg = join('; ', @msgs);
		$TEST->skip($msg);
		return 0;
	}

	return 1;
}

# Helper: run a program with one of the version flags and capture output
sub _capture_version_output {
	my $path = $_[0];

	for my $flag (qw(--version -version -v -V)) {
		my $out;
		my $err;

		eval {
			local $SIG{ALRM} = sub { die 'timeout' };
			alarm(2);  # 2 second timeout

			run3([$path, $flag], \undef, \$out, \$err);

			alarm(0);	# Cancel alarm
		};

		if ($@) {
			alarm(0);	# Ensure alarm is cancelled
			next if $@ =~ /timeout/;
			warn "Error running $path $flag: $@";
			next;
		}

		my $output = defined $out ? $out : '';
		$output .= defined $err ? $err : '';

		next if $output eq '';
		return $output;
	}
	return undef;
}

# Extract the first version-like token from output
sub _extract_version {
	my $output = $_[0];

	return undef unless defined $output;

	# Look for version near the word "version"
	# Handles: "ffmpeg version 4.2.7", "Version: 2.1.0", "ImageMagick 7.1.0-4"
	if ($output =~ /version[:\s]+v?(\d+(?:\.\d+)+)/i) {
		return $1;
	}

	# Look at first line (common pattern)
	my ($first_line) = split /\n/, $output;
	if ($first_line =~ /\b(\d+\.\d+(?:\.\d+)*)\b/) {
		return $1;
	}

	# Any dotted version number
	if ($output =~ /\b(\d+\.\d+(?:\.\d+)*)\b/) {
		return $1;
	}

	# Single number near "version"
	if ($output =~ /version[:\s]+v?(\d+)\b/i) {
		return $1;
	}

	# Just a standalone number (least reliable)
	if ($output =~ /\b(\d+)\b/) {
		return $1;
	}

	return undef;
}

# Compare two versions given an operator
sub _version_satisfies {
	my ($found, $op, $required) = @_;

	return 0 unless defined $found;

	# Parse both versions, checking each separately
	my $vf = eval { version->parse($found) };
	if ($@) {
		warn "Failed to parse found version '$found': $@";
		return 0;
	}

	my $vr = eval { version->parse($required) };
	if ($@) {
		warn "Failed to parse required version '$required': $@";
		return 0;
	}

	# Now do comparisons
	if    ($op eq '>=') { return $vf >= $vr }
	elsif ($op eq '>')  { return $vf >  $vr }
	elsif ($op eq '<=') { return $vf <= $vr }
	elsif ($op eq '<')  { return $vf <  $vr }
	elsif ($op eq '==') { return $vf == $vr }
	elsif ($op eq '!=') { return $vf != $vr }

	warn "Unknown operator '$op'";
	return 0;
}

# Parse a constraint like ">=1.2.3" into (op, ver)
sub _parse_constraint {
	my $spec = $_[0];

	return unless defined $spec;
	if ($spec =~ /^\s*(>=|<=|==|!=|>|<)\s*(\S+)\s*$/) {
		return ($1, $2);
	}
	# allow bare version (==)
	if ($spec =~ /^\s*(\d+(?:\.\d+)*)\s*$/) {
		return ('==', $1);
	}
	return;
}

# Core check routine. Accepts a list of program => maybe_constraint pairs,
# or simple program names in the list form.
sub _check_requirements {
	my (@args) = @_;

	die 'Odd number of arguments (expected program => constraint pairs or program names)' if @args == 0;

	# Normalize into array of hashrefs: { name => ..., constraint => undef or '>=1' }
	my @reqs;
	while (@args) {
		my $a = shift @args;

		die 'Program name must be defined' unless defined $a;

		if (@args && defined $args[0] && ($args[0] =~ /^(?:>=|<=|==|!=|>|<)\s*\d/ || $args[0] =~ /^\d+(?:\.\d+)*$/)) {
			my $c = shift @args;
			push @reqs, { name => $a, constraint => $c };
		} else {
			push @reqs, { name => $a, constraint => undef };
		}
	}

	my @missing;
	my @bad_version;

	for my $r (@reqs) {
		my $name = $r->{name};
		my $want = $r->{constraint};

		my $path = which($name);
		unless ($path) {
			push @missing, $name;
			next;
		}

		if (defined $want) {
			my ($op, $ver) = _parse_constraint($want);
			unless (defined $op) {
				push @bad_version, { name => $name, reason => "invalid constraint '$want'" };
				next;
			}
			my $out = _capture_version_output($path);
			my $found = _extract_version($out);
			unless (defined $found) {
				# Treat as unknown version => requirement not satisfied
				push @bad_version, { name => $name, reason => 'no version detected' };
				next;
			}
			unless (_version_satisfies($found, $op, $ver)) {
				push @bad_version, { name => $name, reason => "found $found but need $op$ver" };
				next;
			}
		}
	}

	return {
		missing => \@missing,
		bad_version => \@bad_version,
	};
}

# import: allow compile-time checks like `use Test::Which 'prog' => '>=1.2';`
sub import {
	my $class = shift;
	$class->export_to_level(1, $class, @EXPORT_OK);

	# Only run requirement checks if any args remain
	my @reqs = grep { $_ ne 'which_ok' } @_;

	return unless @reqs;

	my $res = _check_requirements(@reqs);
	my @missing = @{ $res->{missing} };
	my @bad = @{ $res->{bad_version} };

	if (@missing || @bad) {
		my @msgs;
		push @msgs, map { "Missing required program '$_'" } @missing;
		push @msgs, map { "Version issue for $_->{name}: $_->{reason}" } @bad;
		my $msg = join('; ', @msgs);
		$TEST->plan(skip_all => "Test::Which requirements not met: $msg");
	}
}

1;

__END__

=head1 SUPPORT

This module is provided as-is without any warranty.

=head1 AUTHOR

Nigel Horne, C<< <njh at nigelhorne.com> >>

=head1 LICENCE AND COPYRIGHT

Copyright 2025 Nigel Horne.

Usage is subject to licence terms.

The licence terms of this software are as follows:

=over 4

=item * Personal single user, single computer use: GPL2

=item * All other users (including Commercial, Charity, Educational, Government)
  must apply in writing for a licence for use from Nigel Horne at the
  above e-mail.

=back

=cut
