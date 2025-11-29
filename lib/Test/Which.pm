package Test::Which;

use strict;
use warnings;

use parent 'Exporter';
our @ISA = qw(Exporter);

use File::Which qw(which);
use version ();	# provide version->parse
use Test::Builder;

our @EXPORT_OK = qw(which_ok);
our %EXPORT_TAGS = ( all => \@EXPORT_OK );

my %VERSION_CACHE;
my $TEST = Test::Builder->new();

=head1 NAME

Test::Which - Skip tests if external programs are missing from PATH (with version checks)

=head1 VERSION

Version 0.03

=cut

our $VERSION = '0.03';

=head1 SYNOPSIS

  use Test::Which 'ffmpeg' => '>=6.0', 'convert' => '>=7.1';

  # At runtime in a subtest or test body
  use Test::Which qw(which_ok);

  subtest 'needs ffmpeg' => sub {
	  which_ok 'ffmpeg' => '>=6.0' or return;
	  ... # tests that use ffmpeg
  };

=head1 DESCRIPTION

C<Test::Which> mirrors L<Test::Needs> but checks for executables in PATH.
It can also check simple version constraints using a built-in heuristic (tries --version, -version, -v, -V and extracts a dotted-number).
If a version is requested but cannot be determined, the requirement fails.

=head2 EXAMPLES

  # String constraints
  which_ok 'perl' => '>=5.10';
  which_ok 'ffmpeg' => '>=4.0', 'convert' => '7.1';

  # Regex constraints
  which_ok 'perl', { version => qr/5\.\d+/ };

  # Mixed
  which_ok 'perl' => '>=5.10', 'ffmpeg', { version => qr/^[4-6]\./ };

  # Just program names
  which_ok 'perl', 'ffmpeg', 'convert';

  # String in hashref (for consistency)
  which_ok 'perl', { version => '>=5.10' };

  # Custom Version Extraction
  # Some programs have non-standard version output
  which_ok 'myprogram', {
    version => '>=1.0',
    extractor => sub {
        my $output = shift;
        return $1 if $output =~ /Build (\d+\.\d+)/;
    }
  };

  # Java typically uses -version (single dash)
  which_ok 'java', {
    version => '>=11',
    version_flag => '-version'
};

  # Some programs use /? on Windows
  which_ok 'cmd', {
      version => qr/\d+/,
      version_flag => '/?'
  } if $^O eq 'MSWin32';

  # GCC uses --version but some aliases might need -version
  which_ok 'gcc', {
    version => '>=9.0',
    version_flag => ['--version', '-version']
  };

  # Some tools print version to stdout without any flag
  which_ok 'mytool', {
    version => '>=1.0',
    version_flag => ''  # Empty string means no flag
  };

=head1 FUNCTIONS

=head2 which_ok @programs_or_pairs

Checks the named programs (with optional version constraints).
If any requirement is not met,
the current test or subtest is skipped via L<Test::Builder>.

=head2 Custom Version Flags

Some programs use non-standard flags to display version information.
You can specify custom flags:

  # Single custom flag
  which_ok 'java', {
      version => '>=11',
      version_flag => '-version'
  };

  # Try multiple flags in order
  which_ok 'myprogram', {
      version => '>=2.0',
      version_flag => ['--show-version', '-version']
  };

  # Program prints version without any flag
  which_ok 'sometool', {
      version => '>=1.0',
      version_flag => ''
  };

If version_flag is not specified, the module tries these flags in order:
--version, -version, -v, -V (and /?, -? on Windows)

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

	# Print versions if TEST_VERBOSE is set
	if ($ENV{TEST_WHICH_VERBOSE} || $ENV{TEST_VERBOSE} || $ENV{HARNESS_IS_VERBOSE}) {
		for my $r (@{ $res->{checked} }) {
			my $name = $r->{name};
			my $out = _capture_version_output(which($name), $r->{'version_flag'});
			my $version = _extract_version($out);

			if (defined $version) {
				$TEST->diag("$name: version $version");
			} else {
				$TEST->diag("$name: found but version unknown");
			}
		}
	}

	# Actually run a passing test
	$TEST->ok(1, 'Required programs available: ' . join(', ', map { $_->{name} } @{ $res->{checked} || [] }));
	return 1;
}

# Helper: run a program with one of the version flags and capture output
sub _capture_version_output {
	my ($path, $custom_flags) = @_;

	# Return undef immediately if path is not defined
	return undef unless defined $path;

	# Create cache key from path and flags
	my $cache_key = $path;
	if (defined $custom_flags) {
		if (ref($custom_flags) eq 'ARRAY') {
			$cache_key .= '|' . join(',', @$custom_flags);
		} elsif (!ref($custom_flags)) {
			$cache_key .= '|' . $custom_flags;
		}
	}
	
	# Return cached result if available
	return $VERSION_CACHE{$cache_key} if exists $VERSION_CACHE{$cache_key};

	# Determine which flags to try
	my @flags;
	if (defined $custom_flags) {
		if (ref($custom_flags) eq 'ARRAY') {
			@flags = @$custom_flags;
		} elsif (!ref($custom_flags)) {
			@flags = ($custom_flags);
		} else {
			warn 'Invalid version_flag type: ', ref($custom_flags);
			$VERSION_CACHE{$cache_key} = undef;
			return undef;
		}
	} else {
		@flags = qw(--version -version -v -V);
		# Add Windows-specific flags
		push @flags, qw(/? -?) if $^O eq 'MSWin32';
	}

	for my $flag (@flags) {
		my $out = eval {
			# Platform-specific command construction
			my $cmd;
			if ($flag eq '') {
				if ($^O eq 'MSWin32') {
					$cmd = qq{"$path" 2>&1};
				} else {
					# Escape the path for shell on Unix
					my $escaped = $path;
					$escaped =~ s/'/'\\''/g;
					$cmd = qq{'$escaped' 2>&1};
				}
			} else {
				if ($^O eq 'MSWin32') {
					$cmd = qq{"$path" $flag 2>&1};
				} else {
					# Escape the path for shell on Unix
					my $escaped = $path;
					$escaped =~ s/'/'\\''/g;
					$cmd = qq{'$escaped' $flag 2>&1};
				}
			}
			
			my $output = qx{$cmd};
			return $output;
		};
		
		next unless defined $out;
		next if $out eq '';
		
		# Cache and return the result
		$VERSION_CACHE{$cache_key} = $out;
		return $out;
	}
	
	# Cache the failure (undef) so we don't keep retrying
	$VERSION_CACHE{$cache_key} = undef;
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

	# Normalize version strings to have same number of components
	my @found_parts = split /\./, $found;
	my @req_parts = split /\./, $required;

	# Pad to same length
	my $max_len = @found_parts > @req_parts ? @found_parts : @req_parts;
	push @found_parts, (0) x ($max_len - @found_parts);
	push @req_parts, (0) x ($max_len - @req_parts);

	my $found_normalized = join('.', @found_parts);
	my $req_normalized = join('.', @req_parts);

	# Parse with version.pm
	my $vf = eval { version->parse($found_normalized) };
	if ($@) {
		warn "Failed to parse found version '$found': $@";
		return 0;
	}

	my $vr = eval { version->parse($req_normalized) };
	if ($@) {
		warn "Failed to parse required version '$required': $@";
		return 0;
	}

	# Return explicit 1 or 0
	my $result;
	if ($op eq '>=') { $result = $vf >= $vr }
	elsif ($op eq '>')  { $result = $vf >  $vr }
	elsif ($op eq '<=') { $result = $vf <= $vr }
	elsif ($op eq '<')  { $result = $vf <  $vr }
	elsif ($op eq '==') { $result = $vf == $vr }
	elsif ($op eq '!=') { $result = $vf != $vr }
	else { $result = $vf == $vr }

	return $result ? 1 : 0;
}

# Parse a constraint like ">=1.2.3" into (op, ver)
sub _parse_constraint {
	my $spec = $_[0];

	return unless defined $spec;

	if ($spec =~ /^\s*(>=|<=|==|!=|>|<)\s*([0-9][\w\.\-]*)\s*$/) {
		return ($1, $2);
	}
	# allow bare version (implies ==)
	if ($spec =~ /^\s*(\d+(?:\.\d+)*)\s*$/) {
		return ('==', $1);
	}

	# If we get here, it's invalid
	# Return empty list, but caller should provide an helpful error
	return;
}

# Core check routine. Accepts a list of program => maybe_constraint pairs,
# or simple program names in the list form.
sub _check_requirements {
	my (@args) = @_;

	# Normalize into array of hashrefs: { name => ..., constraint => undef or '>=1' or {version => ...} }
	my @reqs;
	my $i = 0;

	while ($i < @args) {
		my $name = $args[$i];

		# Validate program name
		unless (defined $name) {
			warn "Undefined program name at position $i, skipping";
			$i++;
			next;
		}

		if (ref $name) {
			warn "Program name at position $i cannot be a reference, skipping";
			$i++;
			next;
		}

		$i++;

		# Check if next argument is a constraint
		my $constraint = undef;
		if ($i < @args) {
			my $next = $args[$i];

			if (defined $next) {
				# String constraint: >=1.2.3, >1.0, or bare version 1.2.3
				if (!ref($next)) {
					if ($next =~ /^(?:>=|<=|==|!=|>|<)/ || $next =~ /^\d+(?:\.\d+)*$/) {
						$constraint = $next;
						$i++;
					}
					# Otherwise it's probably the next program name, don't consume it
				} elsif (ref($next) eq 'HASH') {
					# Hashref constraint: { version => qr/.../ } or similar
					$constraint = $next;
					$i++;
				}
			# Other refs (ARRAY, CODE, etc.) - treat as next program name, don't consume
			}
		}

		push @reqs, { name => $name, constraint => $constraint };
	}

	my @missing;
	my @bad_version;
	my @checked;

	for my $r (@reqs) {
		my $name = $r->{name};
		my $want = $r->{constraint};

		my $path = $name;
		if ($name !~ m{^/} && $name !~ m{^[A-Za-z]:[\\/]}) {
			# Not an absolute path, search in PATH
			$path = which($name);
			unless ($path) {
				push @missing, $name;
				next;
			}
		}

		# Verify it's executable
		unless (-x $path) {
			push @bad_version, {
				name => $name,
				reason => "found at $path but not executable"
			};
			next;
		}

		# No version constraint - just check if it exists
		if (!defined $want) {
			push @checked, { name => $name, constraint => undef, version_flag => undef };
			next;
		}

		# Extract custom version flags if provided
		my $version_flag = undef;

		# Handle hashref constraints
		if (ref($want) eq 'HASH') {
			# Currently support { version => ... } and { version_flag => ... }

			# Extract version_flag if present
			$version_flag = $want->{version_flag} if exists $want->{version_flag};

			if($version_flag) {
				$r->{version_flag} = $version_flag;
			}

			if (exists $want->{version}) {
				my $version_spec = $want->{version};
				my $found;
				if (exists $want->{extractor}) {
					my $extractor = $want->{extractor};
					if (ref($extractor) eq 'CODE') {
						my $out = _capture_version_output($path, $version_flag);
						$found = $extractor->($out);
					}
				} else {
					my $out = _capture_version_output($path, $version_flag);
					$found = _extract_version($out);
				}

				unless (defined $found) {
					push @bad_version, {
						name => $name,
						reason => 'no version detected for hashref constraint'
					};
					next;
				}

				# Regex constraint
				if (ref($version_spec) eq 'Regexp') {
					unless ($found =~ $version_spec) {
						push @bad_version, {
							name => $name,
							reason => "found version $found but doesn't match pattern $version_spec"
						};
						next;
					}
				} elsif (!ref($version_spec)) {
					# String constraint within hashref (treat like normal string constraint)
					my ($op, $ver) = _parse_constraint($version_spec);
					unless (defined $op) {
						push @bad_version, {
							name => $name,
							reason => "invalid constraint in hashref '$version_spec' (expected format: '>=1.2.3', '>2.0', '==1.5', or '1.5')"
						};
						next;
					}
					unless (_version_satisfies($found, $op, $ver)) {
						push @bad_version, {
							name => $name,
							reason => "found $found but need $op$ver"
						};
						next;
					}
				} else {
					# Unsupported type in hashref
					push @bad_version, {
						name => $name,
						reason => "unsupported version spec type in hashref: " . ref($version_spec)
					};
					next;
				}
			} else {
				# Hashref without 'version' key
				push @bad_version, {
					name => $name,
					reason => "hashref constraint must contain 'version' key"
				};
				next;
			}
		} elsif (!ref($want)) {
			# Handle string constraints
			my ($op, $ver) = _parse_constraint($want);
			unless (defined $op) {
				push @bad_version, {
					name => $name,
					reason => "invalid constraint '$want' (expected format: '>=1.2.3', '>2.0', '==1.5', or '1.5')"
				};
				next;
			}

			my $out = _capture_version_output($path);
			my $found = _extract_version($out);

			unless (defined $found) {
				push @bad_version, {
					name => $name,
					reason => 'no version detected'
					};
				next;
			}

			unless (_version_satisfies($found, $op, $ver)) {
				push @bad_version, {
					name => $name,
					reason => "found $found but need $op$ver"
				};
				next;
			}
		} else {
			# Unsupported constraint type
			push @bad_version, {
				name => $name,
				reason => "unsupported constraint type: " . ref($want)
			};
			next;
		}

		# If we got here, the program passed all checks
		push @checked, $r;
	}

	return {
		missing => \@missing,
		bad_version => \@bad_version,
		checked => \@checked
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

	# Print versions if TEST_VERBOSE is set
	if ($ENV{TEST_WHICH_VERBOSE} || $ENV{TEST_VERBOSE} || $ENV{HARNESS_IS_VERBOSE}) {
		for my $r (@{ $res->{checked} }) {
			my $name = $r->{name};
			my $out = _capture_version_output(which($name), $r->{'version_flag'});
			my $version = _extract_version($out);

			if (defined $version) {
				print STDERR "# $name: version $version\n";
			} else {
				print STDERR "# $name: found but version unknown\n";
			}
		}
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
