#!/usr/bin/env perl
use strict;
use warnings;
use Test::Most;
use File::Temp qw(tempdir);
use File::Spec;
use File::Which qw(which);

my $tempdir = tempdir(CLEANUP => 1);
$ENV{PATH} = "$tempdir:$ENV{PATH}";

sub create_mock_program {
    my ($name, $script_content) = @_;
    my $path = File::Spec->catfile($tempdir, $name);
    open my $fh, '>', $path or die "Cannot create $path: $!";
    print $fh $script_content;
    close $fh;
    chmod 0755, $path or die "Cannot chmod $path: $!";
    return $path;
}

subtest 'debug version comparison' => sub {
    use_ok('Test::Which');
    
    # Test _parse_constraint
    my ($op, $ver) = Test::Which::_parse_constraint('>=2020.10');
    is($op, '>=', 'operator parsed correctly');
    is($ver, '2020.10', 'version parsed correctly');
    
    # Test _version_satisfies
    my $result = Test::Which::_version_satisfies('2020.10.15', '>=', '2020.10');
    diag("_version_satisfies('2020.10.15', '>=', '2020.10') = " . ($result // 'undef'));
    ok($result, 'version comparison should work');
    
    # If it still fails, test with version.pm directly
    require version;
    my $v1 = version->parse('2020.10.15');
    my $v2 = version->parse('2020.10');
    diag("version objects: $v1 >= $v2 = " . ($v1 >= $v2));
    ok($v1 >= $v2, 'direct version comparison works');
};

subtest 'full integration test' => sub {
    my $prog = create_mock_program('weirdver', <<'EOF');
#!/bin/sh
if [ "$1" = "-version" ]; then
    echo "Build 2020.10.15-git-abc123"
    exit 0
fi
exit 1
EOF

    use_ok('Test::Which', 'which_ok');
    
    my $result = which_ok('weirdver', {
        version => '>=2020.10',
        version_flag => '-version'
    });
    
    ok($result, 'which_ok should succeed') or do {
        # If it fails, run _check_requirements directly to see why
        my $res = Test::Which::_check_requirements('weirdver', {
            version => '>=2020.10',
            version_flag => '-version'
        });
        
        diag("Missing: " . join(', ', @{$res->{missing}}));
        diag("Bad version: " . join(', ', map { "$_->{name}: $_->{reason}" } @{$res->{bad_version}}));
    };
};

done_testing();
