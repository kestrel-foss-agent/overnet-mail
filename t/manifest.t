use strictures 2;

use Cwd                qw(getcwd abs_path);
use ExtUtils::Manifest qw(manicheck filecheck);
use File::Copy         qw(copy);
use File::Path         qw(make_path);
use File::Temp         qw(tempdir);
use Test2::V0;

is [manicheck()], [], 'every MANIFEST entry exists';
is [filecheck()], [], 'all distributable files are in MANIFEST';

# Exercise the actual packaging wrapper with a real Perl and a make double.
# This catches distcheck's successful exit status on manifest omissions.
my $root = tempdir(CLEANUP => 1);
make_path("$root/scripts", "$root/bin", "$root/t");
copy('scripts/check.sh', "$root/scripts/check.sh") or die "copy wrapper: $!";
write_file("$root/bin/make", "#!/bin/sh\nexit 0\n");
chmod 0755, "$root/bin/make" or die "chmod make double: $!";
write_file("$root/Makefile.PL",   "exit 0;\n");
write_file("$root/MANIFEST",      "MANIFEST\nMANIFEST.SKIP\nMakefile.PL\nscripts/check.sh\n");
write_file("$root/MANIFEST.SKIP", "^bin/\n");

local $ENV{PATH} = "$root/bin:$ENV{PATH}";
is system('bash', "$root/scripts/check.sh", 'dist'), 0, 'complete manifest reaches packaging';
write_file("$root/t/unlisted.t", "# deliberately unlisted\n");
ok system('bash', "$root/scripts/check.sh", 'dist') != 0, 'unlisted test fails before distribution build';
unlink "$root/t/unlisted.t" or die "remove fixture: $!";
write_file("$root/MANIFEST", "MANIFEST\nMANIFEST.SKIP\nMakefile.PL\nscripts/check.sh\nmissing.pm\n");
ok system('bash', "$root/scripts/check.sh", 'dist') != 0, 'missing listed source fails before distribution build';

done_testing;

sub write_file {
  my ($path, $content) = @_;
  open my $handle, '>', $path or die "write $path: $!";
  print {$handle} $content;
  close $handle or die "close $path: $!";
  return;
}
