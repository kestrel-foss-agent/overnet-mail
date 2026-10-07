use strictures 2;

use Test2::V0;

my @workflows = sort glob '.github/workflows/*.yml';
ok scalar(@workflows), 'workflows are present';
for my $path (@workflows) {
  my $source = slurp($path);
  like $source, qr/permissions:\s*\n\s+contents: read/, "$path has read-only token permissions";
  for my $line (split /\n/, $source) {
    next if $line !~ /\buses:\s*(\S+)/;
    like $1, qr{\A[\w.-]+/[\w./-]+\@[a-f0-9]{40}\z}, "$path pins every external action by full SHA";
  }
  like $source,   qr/sudo apt-get install -y libgmp-dev/, "$path installs the native Blossom dependency prerequisite";
  unlike $source, qr/pull_request_target/,                "$path never runs PR code with privileged triggers";
}
my $ci = slurp('.github/workflows/perl-tests.yml');
like $ci, qr/^  push:\s*\n  pull_request:/m, 'feature branch pushes run CI before a PR is opened';
like $ci, qr/perl: \['5[.]40', 'latest'\]/,  'minimum and current stable Perl are tested';
for my $gate (qw(test author coverage dist)) {
  like $ci, qr/\Qbash scripts\/check.sh $gate\E/, "$gate is required by CI";
}
my $checks = slurp('scripts/check.sh');
like $checks, qr/perl -e 'require Devel::Cover; require Devel::Cover::DB'/,
  'coverage dependency absence fails before template without starting instrumentation';
for my $floor ('STATEMENT=95', 'BRANCH=85', 'SUBROUTINE=100') {
  like $checks, qr/\QOVERNET_COVERAGE_MIN_$floor\E/, "coverage floor $floor is explicit";
}
like $checks, qr/--severity 1 --only lib/, 'lint explicitly inspects source independent of blib';
like $checks, qr/--single-policy Overnet::RequireTest2InTests t xt\/author/,
  'Test2 policy checks every application test';
like slurp('scripts/install-deps.sh'), qr{cpanm [.]\/vendor/overnet-perl-style}, 'custom policies are installed';
my $mutation = slurp('.github/workflows/mutation.yml');
unlike $mutation, qr/^  (?:push|pull_request):/m,       'mutation is manual-only';
like $checks,     qr/OVERNET_MUTATION_MAX_SURVIVORS=0/, 'mutation tolerates zero unreviewed survivors';

for my $script (glob 'scripts/*.sh') {
  is system('bash', '-n', $script), 0, "$script has valid shell syntax";
}

done_testing;

sub slurp {
  my ($path) = @_;
  open my $handle, '<', $path or die "$path: $!";
  local $/;
  my $text = <$handle>;
  close $handle or die "$path: $!";
  return $text;
}
