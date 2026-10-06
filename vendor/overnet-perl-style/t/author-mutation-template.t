use strictures 2;

use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Test2::V0;

my $template = "$FindBin::Bin/../configs/test-templates/xt/author/mutation.t";

ok -f $template, 'mutation template exists' or bail_out('no template to inspect');

open my $handle, '<', $template
  or die "Cannot open $template: $!";
my $content = do { local $/; <$handle> };
close $handle;

# --- Shape checks: cheap, and run even where Devel::Mutator is absent. ---
like $content, qr/\Quse strictures 2;\E/xm, 'template uses strictures 2';
like $content, qr/\QTest2::V0\E/xm,         'template uses Test2::V0';
like $content, qr/skip_all/xm,                          'template can skip itself';
like $content, qr/\$ENV\{OVERNET_MUTATION\}/xm,         'mutation is opt-in via OVERNET_MUTATION';
like $content, qr/\QDevel::Mutator\E/xm,                'template drives Devel::Mutator';
like $content, qr/\Qrequire Devel::Mutator\E/xm,        'template skips when Devel::Mutator is unavailable';
like $content, qr/\QOVERNET_MUTATION_FILES\E/xm,        'the target module list is required and explicit';
like $content, qr/\QOVERNET_MUTATION_TEST_COMMAND\E/xm, 'the per-mutant test command is configurable';
like $content, qr/tempdir/xm,                           'the run is isolated in a throwaway work tree';
like $content, qr/File::Spec->updir/xm, 'the work tree sits beside the repo so sibling-relative paths still resolve';
like $content, qr/\QResult:\E/xm,   'the Devel::Mutator result line is parsed';
like $content, qr/\@survivors/xm,   'surviving mutants are counted and gated';
like $content, qr/\QOVERNET_MUTATION_ALLOW\E/xm, 'reviewed survivors are pinned in an allowlist';
like $content, qr/\@unreviewed/xm,  'only unreviewed survivors fail the gate';
like $content, qr/baseline/xm,      'the unmutated suite is checked green before mutating';

# --- Behavioural checks: actually run the template against a controlled dist. ---
SKIP: {
  my $have = eval { require Devel::Mutator; require Capture::Tiny; 1 };
  skip 'Devel::Mutator is not installed; skipping functional mutation checks', 8
    if !$have;

  my $base    = tempdir(CLEANUP => 1);
  my $fixture = File::Spec->catdir($base, 'sample-dist');
  _build_fixture($fixture, $content);

  # A strong suite kills every mutant of the sample module: the template passes.
  my ($strong_out, $strong_exit) = _run_template($fixture, 'prove -Ilib t/strong.t');
  is $strong_exit, 0, 'template passes when a strong suite kills every mutant'
    or diag $strong_out;
  like $strong_out, qr/unreviewed \s surviving \s mutants \s \(0\)/xm, 'a strong suite leaves no survivors';

  # A weak suite executes the code but asserts nothing discriminating, so mutants
  # survive and the template fails -- this is the whole point of the tool.
  my ($weak_out, $weak_exit) = _run_template($fixture, 'prove -Ilib t/weak.t');
  isnt $weak_exit, 0, 'template fails when a weak suite lets mutants survive';
  like $weak_out, qr/unreviewed \s surviving \s mutants \s \([1-9]/xm, 'a weak suite leaves survivors';

  # The survivor report must emit paste-ready blocks, and feeding those exact
  # blocks back as the allowlist must make the gate accept them -- proving the
  # emit format equals the accept format, so a reviewer's paste always matches.
  my @blocks = _extract_survivor_blocks($weak_out);
  is scalar(@blocks), 3, 'the survivor report lists each mutant as a paste-ready block';
  _write("$fixture/xt/author/mutation-allow.txt", join("\n\n", @blocks) . "\n");
  my ($allow_out, $allow_exit) = _run_template($fixture, 'prove -Ilib t/weak.t');
  is $allow_exit, 0, 'allowlisting the reviewed survivors makes the gate pass'
    or diag $allow_out;
  like $allow_out, qr/allowlisted/xm, 'accepted survivors are reported as allowlisted';

  # A red baseline must be rejected, not reported as a clean (zero-survivor) pass.
  my ($bad_out, undef) = _run_template($fixture, 'prove -Ilib t/bad.t');
  like $bad_out, qr/not \s ok .* valid \s mutation \s baseline/xms,
    'template rejects a red baseline instead of reporting a false pass';
}

done_testing();

sub _build_fixture {
  my ($fixture, $template_source) = @_;

  make_path(File::Spec->catdir($fixture, 'lib'));
  make_path(File::Spec->catdir($fixture, 't'));
  make_path(File::Spec->catdir($fixture, 'xt', 'author'));

  # Three mapped operators (>, ==, +) => exactly three mutants, none equivalent.
  _write(
    "$fixture/lib/Sample.pm", <<'SAMPLE');
package Sample;
use strictures 2;
sub classify { my ($n) = @_; return 'positive' if $n > 0; return 'zero' if $n == 0; return 'negative'; }
sub add { my ($a, $b) = @_; return $a + $b; }
1;
SAMPLE

  # Strong: boundary assertions that kill all three mutants.
  _write(
    "$fixture/t/strong.t", <<'STRONG');
use strictures 2;
use Test2::V0;
use Sample;
is Sample::classify(1),  'positive';
is Sample::classify(0),  'zero';
is Sample::classify(-1), 'negative';
is Sample::add(2, 3), 5;
done_testing;
STRONG

  # Weak: runs the code but asserts nothing that a mutation would break.
  _write(
    "$fixture/t/weak.t", <<'WEAK');
use strictures 2;
use Test2::V0;
use Sample;
ok defined Sample::classify(5);
ok defined Sample::add(1, 1);
done_testing;
WEAK

  # Deliberately failing suite, to exercise the green-baseline guard.
  _write(
    "$fixture/t/bad.t", <<'BAD');
use strictures 2;
use Test2::V0;
is 1, 2, 'deliberately failing baseline';
done_testing;
BAD

  _write("$fixture/xt/author/mutation.t", $template_source);
  return;
}

sub _run_template {
  my ($fixture, $command) = @_;

  local $ENV{OVERNET_MUTATION}              = 1;
  local $ENV{OVERNET_MUTATION_FILES}        = 'lib/Sample.pm';
  local $ENV{OVERNET_MUTATION_TEST_COMMAND} = $command;
  local $ENV{OVERNET_MUTATION_TIMEOUT}      = 30;

  my ($output, $status) = Capture::Tiny::capture_merged(sub {
    system $^X, "$fixture/xt/author/mutation.t";
  });
  return ($output, $status >> 8);
}

# Pull the paste-ready survivor blocks back out of the gate's failure diag. The
# gate prints each unreviewed survivor as consecutive "-"/"+" diff lines (carried
# through Test2 diag, so each is prefixed with "# "); a run of them separated by
# any non-diff line is one block. This mirrors what a reviewer would copy out of
# the terminal, so feeding the result straight back as the allowlist proves the
# emit format and the accept format are the same format.
sub _extract_survivor_blocks {
  my ($out) = @_;
  my (@blocks, @cur);
  for my $line (split /\n/, $out) {
    if ($line =~ /^\#\s?([-+].*)$/) {
      push @cur, $1;
    }
    elsif (@cur) {
      push @blocks, join("\n", @cur);
      @cur = ();
    }
  }
  push @blocks, join("\n", @cur) if @cur;
  return @blocks;
}

sub _write {
  my ($path, $body) = @_;
  open my $fh, '>', $path or die "open $path: $!";
  print {$fh} $body or die "write $path: $!";
  close $fh or die "close $path: $!";
  return;
}
