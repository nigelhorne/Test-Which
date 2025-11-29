#!/usr/bin/env perl
use strict;
use warnings;
use Test::Most;
use File::Temp qw(tempdir);
use File::Spec;
use File::Which qw(which);

BEGIN {
	# FIXME
	if ($^O eq 'MSWin32') {
		plan skip_all => 'Shell script mock programs not compatible with Windows';
	}
}

# Create a temporary directory for our mock programs
my $tempdir = tempdir(CLEANUP => 1);

# Helper to create a mock executable
sub create_mock_program {
	my ($name, $script_content) = @_;
	
	my $path;
	if ($^O eq 'MSWin32') {
		# Create .bat file on Windows
		$path = File::Spec->catfile($tempdir, "$name.bat");
		open my $fh, '>', $path or die "Cannot create $path: $!";
		
		# Convert shell script to batch script
		my $batch_content = '@echo off' . "\n";
		
		# Simple conversion for basic cases
		if ($script_content =~ /echo "([^"]+)"/) {
			$batch_content .= "echo $1\n";
		}
		
		print $fh $batch_content;
		close $fh;
	} else {
		# Unix shell script
		$path = File::Spec->catfile($tempdir, $name);
		open my $fh, '>', $path or die "Cannot create $path: $!";
		print $fh $script_content;
		close $fh;
		chmod 0755, $path or die "Cannot chmod $path: $!";
	}
	
	return $path;
}

# Add tempdir to PATH so which() can find our mock programs
$ENV{PATH} = "$tempdir:$ENV{PATH}";

# First, let's test what the module actually supports
subtest 'verify basic functionality first' => sub {
	my $prog = create_mock_program('basicprog', <<'EOF');
#!/bin/sh
if [ "$1" = "--version" ]; then
	echo "basicprog version 1.2.3"
	exit 0
fi
exit 1
EOF

	use_ok('Test::Which', 'which_ok');

	# Test basic string constraint
	my $result = which_ok('basicprog' => '>=1.0');
	ok($result, 'basic string constraint works') or diag("Result: $result");

	# Test if program can be found
	my $path = which('basicprog');
	ok($path, "basicprog found at: $path");

	# Manually test version detection
	require Test::Which;
	my $output = Test::Which::_capture_version_output($path);
	ok(defined $output, 'Got output: ' . (defined $output ? $output : 'undef'));

	my $version = Test::Which::_extract_version($output);
	is($version, '1.2.3', "Extracted version correctly: " . (defined $version ? $version : 'undef'));
};

# Test 2: Debug hashref support
subtest 'test hashref constraint support' => sub {
	my $prog = create_mock_program('hashprog', <<'EOF');
#!/bin/sh
if [ "$1" = "--version" ]; then
	echo "hashprog version 2.5.1"
	exit 0
fi
exit 1
EOF

	use_ok('Test::Which', 'which_ok');

	# Test if hashref is accepted at all
	my $result;
	lives_ok {
		$result = which_ok('hashprog', { version => '>=2.0' });
	} 'hashref constraint does not die';

	ok($result, 'hashref with string version works')
		or diag("Hashref constraint failed - may not be implemented yet");
};

# Test 3: Custom version flag with string constraint (simpler case)
subtest 'custom version flag - string constraint only' => sub {
	my $prog = create_mock_program('customprog', <<'EOF');
#!/bin/sh
if [ "$1" = "-H" ]; then
	echo "customprog 3.0.0"
	exit 0
fi
exit 1
EOF

	use_ok('Test::Which', 'which_ok');

	# First verify it fails with default flags
	my $result1 = which_ok('customprog' => '>=3.0');
	ok(!$result1, 'fails with default flags (as expected)');

	# Now test with custom flag in hashref
	my $result2;
	lives_ok {
		$result2 = which_ok('customprog', {
			version => '>=3.0',
			version_flag => '-H'
		});
	} 'custom version_flag does not die';

	ok($result2, 'succeeds with custom version_flag')
		or diag('Custom version_flag may not be implemented yet');
};

# Test 4: Verify _capture_version_output accepts second parameter
subtest 'test _capture_version_output with custom flag' => sub {
	my $prog = create_mock_program('flagprog', <<'EOF');
#!/bin/sh
if [ "$1" = "-show-ver" ]; then
	echo "flagprog 1.5.0"
	exit 0
fi
exit 1
EOF

	use_ok('Test::Which');

	my $path = which('flagprog');
	ok($path, "flagprog found");

	# Test default behavior
	my $output1 = Test::Which::_capture_version_output($path);
	ok(!defined $output1 || $output1 eq '',
		'no output with default flags (as expected)');

	# Test with custom flag
	my $output2;
	lives_ok {
		$output2 = Test::Which::_capture_version_output($path, '-show-ver');
	} '_capture_version_output accepts second parameter';

	like($output2 || '', qr/1\.5\.0/, 'custom flag returns version')
		or diag("Output with custom flag: " . ($output2 || 'undef'));
};

# Test 5: Test array of flags
subtest 'test array of version flags' => sub {
	my $prog = create_mock_program('arrayprog', <<'EOF');
#!/bin/sh
if [ "$1" = "-ver" ]; then
	echo "arrayprog 2.0.0"
	exit 0
fi
exit 1
EOF

	use_ok('Test::Which', 'which_ok');

	my $result;
	lives_ok {
		$result = which_ok('arrayprog', {
			version => '>=2.0',
			version_flag => ['--version', '-ver']
		});
	} 'array of version_flags does not die';

	ok($result, 'array of flags works')
		or diag("Array version_flag may not be implemented yet");
};

# Test 6: Test regex constraint
subtest 'test regex constraint' => sub {
	my $prog = create_mock_program('regexprog', <<'EOF');
#!/bin/sh
if [ "$1" = "--version" ]; then
	echo "regexprog 5.10.1"
	exit 0
fi
exit 1
EOF

	use_ok('Test::Which', 'which_ok');

	my $result;
	lives_ok {
		$result = which_ok('regexprog', {
			version => qr/^5\.\d+/
		});
	} 'regex constraint does not die';

	ok($result, 'regex constraint works')
		or diag("Regex constraint may not be implemented yet");
};

# Test 7: Empty version flag
subtest 'test empty version flag' => sub {
	my $prog = create_mock_program('noflagprog', <<'EOF');
#!/bin/sh
if [ $# -eq 0 ]; then
	echo "noflagprog 1.0.0"
	exit 0
fi
exit 1
EOF

	use_ok('Test::Which', 'which_ok');

	my $result;
	lives_ok {
		$result = which_ok('noflagprog', {
			version => '>=1.0',
			version_flag => ''
		});
	} 'empty version_flag does not die';

	ok($result, 'empty string flag works')
		or diag('Empty version_flag may not be implemented yet');
};

# Test 8: Show what needs to be implemented
subtest 'summary of implementation status' => sub {
	note('This test summarizes what features are working');

	# You can add manual checks here based on earlier test results
	pass('Check earlier subtests for implementation status');
};

done_testing();
