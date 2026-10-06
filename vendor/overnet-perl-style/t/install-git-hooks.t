use strictures 2;

use Cwd        qw(abs_path getcwd);
use File::Temp qw(tempdir);
use FindBin;
use Test2::V0;

my $style_root = abs_path("$FindBin::Bin/..");
my @repo_roots = ( tempdir( CLEANUP => 1 ), tempdir( CLEANUP => 1 ), );

for my $repo_root (@repo_roots) {
    system( 'git', 'init', '-q', $repo_root ) == 0
      or die "Cannot initialize temporary git repo";
}

system( "$style_root/tools/install-git-hooks", @repo_roots ) == 0
  or die "install-git-hooks failed";

for my $repo_root (@repo_roots) {
    chomp( my $hooks_path = `git -C "$repo_root" config --get core.hooksPath` );
    is $hooks_path, "$style_root/configs/git-hooks",
      'core.hooksPath points at shared hooks';
}

my $hook_repo_root = tempdir( CLEANUP => 1 );
system( 'git', 'init', '-q', $hook_repo_root ) == 0
  or die "Cannot initialize temporary git repo";

my $fake_perlcritic = "$hook_repo_root/fake-perlcritic";
open my $perlcritic_fh, '>', $fake_perlcritic
  or die "Cannot create fake perlcritic";
print {$perlcritic_fh} <<'SCRIPT';
#!/usr/bin/env bash
{
  printf '%s\n' '---'
  printf '%s\n' "$@"
} >> "$FAKE_PERLCRITIC_ARGS"
SCRIPT
close $perlcritic_fh
  or die "Cannot close fake perlcritic";
chmod 0755, $fake_perlcritic
  or die "Cannot make fake perlcritic executable";

{
    local $ENV{PERLCRITIC} = $fake_perlcritic;
    system( "$style_root/tools/install-git-hooks", $hook_repo_root ) == 0
      or die "install-git-hooks failed";
}

chomp( my $configured_perlcritic =
      `git -C "$hook_repo_root" config --get overnet.perlcritic.bin` );
is $configured_perlcritic, $fake_perlcritic,
  'install-git-hooks records configured perlcritic';

open my $profile_fh, '>', "$hook_repo_root/.perlcriticrc"
  or die "Cannot create Perl::Critic profile";
close $profile_fh
  or die "Cannot close Perl::Critic profile";

open my $perl_fh, '>', "$hook_repo_root/hook-target.pl"
  or die "Cannot create hook target";
print {$perl_fh} "use strictures 2;\n";
close $perl_fh
  or die "Cannot close hook target";

open my $test_fh, '>', "$hook_repo_root/hook-target.t"
  or die "Cannot create hook test target";
print {$test_fh} "use strictures 2;\nuse Test::More;\ndone_testing;\n";
close $test_fh
  or die "Cannot close hook test target";

mkdir "$hook_repo_root/t"
  or die "Cannot create test helper directory";
open my $helper_fh, '>', "$hook_repo_root/t/hook-helper.pl"
  or die "Cannot create hook test helper";
print {$helper_fh} "use strictures 2;\n";
close $helper_fh
  or die "Cannot close hook test helper";

system( 'git', '-C', $hook_repo_root, 'add', '.perlcriticrc', 'hook-target.pl',
    'hook-target.t', 't/hook-helper.pl' ) == 0
  or die "Cannot stage hook target";

my $cwd       = getcwd();
my $args_file = "$hook_repo_root/perlcritic.args";
chdir $hook_repo_root
  or die "Cannot chdir to hook repo";
{
    local $ENV{PATH}                 = '/usr/bin:/bin';
    local $ENV{FAKE_PERLCRITIC_ARGS} = $args_file;
    local $ENV{PERLCRITIC};
    delete $ENV{PERLCRITIC};

    is system("$style_root/configs/git-hooks/pre-commit"), 0,
      'pre-commit uses configured perlcritic';
}
chdir $cwd
  or die "Cannot restore cwd";

open my $args_fh, '<', $args_file
  or die "Cannot read perlcritic args";
my $args = do { local $/; <$args_fh> };
like $args, qr/\Q--profile\E/xm,      'perlcritic receives profile option';
like $args, qr/\Q.perlcriticrc\E/xm,  'perlcritic receives configured profile';
like $args, qr/\Qhook-target.pl\E/xm, 'perlcritic receives staged Perl path';
like $args, qr/\Q--single-policy\E\n\QOvernet::RequireTest2InTests\E/xm,
  'test files use the Test2 policy';
like $args, qr/\Q--only\E/xm,
  'test file policy invocation is limited to explicitly selected policy';
like $args, qr/\Qhook-target.t\E/xm, 'perlcritic receives staged test path';
unlike $args, qr{\Qt/hook-helper.pl\E}xm,
  'pre-commit skips Perl helpers under test directories';

done_testing();
