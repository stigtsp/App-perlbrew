#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib $FindBin::Bin;
use App::perlbrew;
require "test_helpers.pl";
use File::Spec;
use Test::Exception;
use Test::More tests => 12;
use File::Temp 'tempfile';

my $testdir = $FindBin::Bin;
my $testfile = sub { return File::Spec->catfile($testdir, shift) };
my $app = App::perlbrew->new;

my $sigfailre = qr/PGP signature validation FAILED/;
my $chkfailre = qr/Checksum verification FAILED/;

my ($wh, $pause_keyring) = tempfile(CLEANUP=>0);
print $wh $app->PAUSE_PGP_KEYRING;
close $wh;


lives_ok {
    $app->digest_verify(&$testfile('test.tar.gz'),
                         &$testfile('CHECKSUMS-test-sig'))
} 'CHECKSUMS against test.tar.gz';

throws_ok {
    $app->digest_verify(&$testfile('corrupt.tar.gz'),
                         &$testfile('CHECKSUMS-test-sig'))
} $chkfailre,'CHECKSUMS against corrupt.tar.gz';



skip "The following tests needs gpg installed", 10 unless $app->has_gpg;

# gpgv verification of CHECKSUMS signature

lives_and {
    is $app->gpgv_verify(&$testfile('CHECKSUMS-pause-sig'),
                          $pause_keyring), 1;
} 'Valid CHECKSUMS against valid keyring validates';

throws_ok {
    $app->gpgv_verify(&$testfile('CHECKSUMS-invalid-data'),
                       $pause_keyring);
} $sigfailre, 'Invalid CHECKSUMS against valid keyring dies';

throws_ok {
    $app->gpgv_verify(&$testfile('CHECKSUMS-test-sig'),
                       $pause_keyring);
} $sigfailre, 'Invalid CHECKSUMS against correct keyring dies';

throws_ok {
    $app->gpgv_verify(&$testfile('CHECKSUMS-pause-sig'),
                       &$testfile('keyring-test.gpg'));
} $sigfailre, 'Valid CHECKSUMS against keyring without valid key';

throws_ok {
    $app->gpgv_verify(&$testfile('CHECKSUMS-test-unsigned'),
                       &$testfile('keyring-test.gpg'));
} $sigfailre, 'Unsigned CHECKSUMS fails';


lives_and {
    is $app->gpgv_verify(&$testfile('CHECKSUMS-test-sig'),
                          &$testfile('keyring-test.gpg')), 1;
} 'Test signed CHECKSUMS against test signed keyring validates';


# wrapper

my $orig_keyring = \&App::perlbrew::keyring;

no warnings;
*App::perlbrew::keyring = sub {return $pause_keyring};

throws_ok {
    $app->verify_tarball(&$testfile('test.tar.gz'), &$testfile('CHECKSUMS-test-sig'));
} $sigfailre, 'Verify tarball with CHECKSUMS from untrusted test fails';

*App::perlbrew::keyring = sub {return &$testfile('keyring-test.gpg')};


lives_ok {
    $app->verify_tarball(&$testfile('test.tar.gz'), &$testfile('CHECKSUMS-test-sig'));
} 'Verify tarball with trusted checksums is ok';

throws_ok {
    $app->verify_tarball(&$testfile('corrupt.tar.gz'), &$testfile('CHECKSUMS-test-sig'));
} $chkfailre, 'Verify corrupted tarball with fails';

throws_ok {
    $app->verify_tarball(&$testfile('notfound.tar.gz'), &$testfile('CHECKSUMS-test-sig'));
} qr/not found in CHECKSUMS/, 'Verify tarball thats not in CHECKSUMS fails';

*App::perlbrew::keyring = $orig_keyring;


done_testing();



