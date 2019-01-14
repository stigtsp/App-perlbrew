#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib $FindBin::Bin;
use App::perlbrew;
require "test_helpers.pl";
use File::Spec;
use Test::Exception;
use Test::More tests => 13;
use File::Temp 'tempfile';

my $app = App::perlbrew->new;

my $testdir = $FindBin::Bin;
sub tfn { return File::Spec->catfile($testdir, "verification", shift) }
sub slurp {
    my $fn = shift;
    local undef $/;
    open(my $fh, $fn);
    my $r = <$fh>;
    return $r;
}
sub strip_clearsign {
    my $d = shift;
    my ($msg) = $d =~ m/.*-----BEGIN PGP SIGNED MESSAGE-----\nHash:.+?\n\n(.+?)-----BEGIN PGP SIGNATURE-----/sg;
    die "no msg" unless defined $msg && $msg;
    return $msg;
}


my $sigfailre = qr/PGP signature verification FAILED/;
my $chkfailre = qr/Checksum verification FAILED/;

my ($wh, $pause_keyring) = tempfile(CLEANUP => 1);
print $wh $app->PAUSE_PGP_KEYRING;


lives_ok {
    $app->digest_verify(tfn('test.tar.gz'), slurp(tfn('CHECKSUMS-test-sig')))
} 'CHECKSUMS against test.tar.gz';

throws_ok {
    $app->digest_verify(tfn('corrupt.tar.gz'), slurp(tfn('CHECKSUMS-test-sig')))
} $chkfailre,'CHECKSUMS against corrupt.tar.gz';

skip "The following tests needs gpg installed", 10 unless $app->has_gpg;
# gpgv verification of CHECKSUMS signature

lives_and {
    my $d = tfn('CHECKSUMS-pause-sig');
    is $app->gpgv_verified_output($d, $pause_keyring), strip_clearsign(slurp($d));
} 'Valid CHECKSUMS against valid keyring lives';

throws_ok {
    $app->gpgv_verified_output(tfn('CHECKSUMS-invalid-data'), $pause_keyring);
} $sigfailre, 'Invalid CHECKSUMS against valid keyring dies';

throws_ok {
    $app->gpgv_verified_output(tfn('CHECKSUMS-test-sig'), $pause_keyring);
} $sigfailre, 'Invalid CHECKSUMS against correct keyring dies';

throws_ok {
    $app->gpgv_verified_output(tfn('CHECKSUMS-pause-sig'), tfn('keyring-test.gpg'));
} $sigfailre, 'Valid CHECKSUMS against keyring with invalid key dies';

throws_ok {
    $app->gpgv_verified_output(tfn('CHECKSUMS-test-unsigned'),tfn('keyring-test.gpg'));
} $sigfailre, 'Unsigned CHECKSUMS dies';


lives_and {
    my $d = tfn('CHECKSUMS-test-sig');
    is $app->gpgv_verified_output(tfn('CHECKSUMS-test-sig'), tfn('keyring-test.gpg')), strip_clearsign(slurp($d));
} 'Test signed CHECKSUMS against test keyring lives';

lives_and {
    my $chkf = tfn('CHECKSUMS-test-sig-evil-code');
    my $data = $app->gpgv_verified_output($chkf, tfn('keyring-test.gpg'));
    unlike $data, qr/EVIL CODE/, 'No EVIL CODE';
} 'Test signed CHECKSUMS with EVIL CODE against test keyring lives, and doesnt contain EVIL CODE';

# wrapper
my $orig_keyring = \&App::perlbrew::keyring;

no warnings;
*App::perlbrew::keyring = sub {return $pause_keyring};

throws_ok {
    $app->verify_tarball(tfn('test.tar.gz'), tfn('CHECKSUMS-test-sig'));
} $sigfailre, 'Verify tarball with CHECKSUMS from untrusted test fails';

*App::perlbrew::keyring = sub {return tfn('keyring-test.gpg')};


lives_ok {
    $app->verify_tarball(tfn('test.tar.gz'), tfn('CHECKSUMS-test-sig'));
} 'Verify tarball with trusted checksums is ok';

throws_ok {
    $app->verify_tarball(tfn('corrupt.tar.gz'), tfn('CHECKSUMS-test-sig'));
} $chkfailre, 'Verify corrupted tarball with fails';

throws_ok {
    $app->verify_tarball(tfn('notfound.tar.gz'), tfn('CHECKSUMS-test-sig'));
} qr/not found in CHECKSUMS/, 'Verify tarball thats not in CHECKSUMS fails';

*App::perlbrew::keyring = $orig_keyring;


done_testing();



