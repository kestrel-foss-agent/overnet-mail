use strictures 2;

use Cwd        qw(abs_path);
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Test2::V0;

# Test wrapper control flow with isolated command doubles. These are not the
# application coverage measurements; CI separately runs the real quality tools.
my $root = tempdir(CLEANUP => 1);
make_path("$root/scripts", "$root/bin", "$root/lib/Overnet", "$root/vendor/overnet-perl-style");
copy('scripts/check.sh', "$root/scripts/check.sh") or die "copy runner: $!";
write_file("$root/lib/Overnet/Mail.pm", "placeholder\n");
my $double = <<'SHELL';
#!/usr/bin/env bash
name=${0##*/}
printf '%s %s | coverage=%s floors=%s/%s/%s mutation=%s survivors=%s\n' \
  "$name" "$*" "${OVERNET_COVERAGE-}" "${OVERNET_COVERAGE_MIN_STATEMENT-}" \
  "${OVERNET_COVERAGE_MIN_BRANCH-}" "${OVERNET_COVERAGE_MIN_SUBROUTINE-}" \
  "${OVERNET_MUTATION-}" "${OVERNET_MUTATION_MAX_SURVIVORS-}" >> "$RUNNER_LOG"
if [[ "$name" == "${FAIL_TOOL-}" ]]; then exit 31; fi
SHELL
for my $name (qw(perl prove perlcritic make)) {
  write_file("$root/bin/$name", $double);
  chmod 0755, "$root/bin/$name" or die "chmod command double: $!";
}

my ($status, $log) = run_case('coverage');
is $status, 0, 'coverage wrapper succeeds when tools succeed';
like $log, qr/perl -e require Devel::Cover; require Devel::Cover::DB/, 'coverage loads required tools first';
like $log, qr/prove -lv xt\/author\/devel-cover[.]t \| coverage=1 floors=95\/85\/100/,
  'wrapper forces coverage collection and floors';

($status, $log) = run_case('coverage', FAIL_TOOL => 'perl');
is $status, 31, 'missing coverage dependency fails closed';
unlike $log, qr/^prove /m, 'skippable template never runs after failed preflight';

($status, $log) = run_case('coverage', FAIL_TOOL => 'prove');
is $status, 31, 'coverage failure is propagated';

($status, $log) = run_case('author', FAIL_TOOL => 'perlcritic');
is $status, 31, 'critic failure is propagated';
unlike $log, qr/^prove /m, 'author suite does not conceal a preceding critic failure';

for my $targets (q{}, '   ', 'lib/Absent.pm', '../outside.pm', 'lib/../outside.pm', 'lib/*.pm') {
  ($status, $log) = run_case('mutation', OVERNET_MUTATION_FILES => $targets);
  ok $status != 0, "mutation refuses invalid target list [$targets]";
  unlike $log, qr/^prove /m, 'invalid targets cannot turn into a skipped-success template run';
}

($status, $log) = run_case('mutation', OVERNET_MUTATION_FILES => 'lib/Overnet/Mail.pm');
is $status, 0, 'valid explicit mutation target reaches the gate';
like $log, qr/prove -lv xt\/author\/mutation[.]t .*mutation=1 survivors=0/,
  'mutation is enabled with zero survivor tolerance';

($status, $log) = run_case('unknown');
is $status, 2, 'unknown check is rejected';

($status, $log) = run_case('test', FAIL_TOOL => 'make');
is $status, 31, 'normal test failure propagates';
unlike $log, qr/^prove /m, 'a later test command cannot mask make failure';

done_testing;

sub run_case {
  my ($gate, %env) = @_;
  local %ENV = %ENV;
  delete @ENV{qw(FAIL_TOOL OVERNET_MUTATION_FILES)};
  @ENV{keys %env}                      = values %env;
  $ENV{PATH}                           = "$root/bin:$ENV{PATH}";
  $ENV{RUNNER_LOG}                     = "$root/commands.log";
  $ENV{OVERNET_COVERAGE_MIN_STATEMENT} = 0;
  $ENV{OVERNET_MUTATION_MAX_SURVIVORS} = 99;
  write_file($ENV{RUNNER_LOG}, q{});
  my $status = system('bash', "$root/scripts/check.sh", $gate);
  open my $handle, '<', $ENV{RUNNER_LOG} or die "read command log: $!";
  local $/;
  my $log = <$handle>;
  close $handle or die "close command log: $!";
  return ($status >> 8, $log);
}

sub write_file {
  my ($path, $content) = @_;
  open my $handle, '>', $path or die "write $path: $!";
  print {$handle} $content;
  close $handle or die "close $path: $!";
  return;
}
