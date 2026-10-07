use strictures 2;

use Cwd qw(abs_path getcwd);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Test2::V0;

# Mutation testing with Devel::Mutator. This is the expensive counterpart to the
# coverage gate: coverage asks "did a test execute this line?", mutation asks
# "would a test NOTICE if this line were wrong?". It works by rewriting the
# target modules one small change at a time (== to !=, || to //, and so on) and
# rerunning the suite against each mutant; a mutant that the suite still passes
# is a "survivor" -- code whose behaviour no assertion actually pins down.
#
# It reruns the whole selected suite once per mutant, so it is far too slow for
# a normal author-test pass and is disabled by default. Run it manually, scoped
# to the high-value modules you care about, e.g.:
#
#   OVERNET_MUTATION=1 \
#   OVERNET_MUTATION_FILES=lib/Overnet/Authority/Delegation.pm \
#   OVERNET_MUTATION_TEST_COMMAND='prove -Ilib t/authority-delegation.t' \
#   perl -Ilib xt/author/mutation.t
#
# Devel::Mutator's operator set is narrow (~14 swaps), so treat a clean run as
# "these tests survived a narrow mutation set", not proof of a strong suite.
#
# Equivalent mutants (a change with no observable effect) survive but are not
# real gaps. Rather than a blunt tolerated-count, reviewed survivors are pinned
# individually in an allowlist file (default xt/author/mutation-allow.txt): each
# entry is the changed (-/+) diff lines of a survivor a human has judged
# equivalent or intentional. A survivor that matches an allowlist entry is
# accepted; any *unreviewed* survivor still fails the gate, so a new real gap is
# never hidden by an accepted equivalent. On failure the gate prints each
# unreviewed survivor in exactly the format the allowlist expects, ready to
# paste in after review.
#
# Knobs (all optional except the two above):
#   OVERNET_MUTATION_FILES          colon/space separated lib/ modules to mutate
#   OVERNET_MUTATION_TEST_COMMAND   suite to run per mutant (default: prove -Ilib t)
#   OVERNET_MUTATION_TIMEOUT        per-mutant seconds before "inconclusive" (default 120)
#   OVERNET_MUTATION_MAX_SURVIVORS  tolerated UNREVIEWED survivors (default 0)
#   OVERNET_MUTATION_ALLOW          allowlist path (default xt/author/mutation-allow.txt)

if (!$ENV{OVERNET_MUTATION}) {
  plan skip_all => 'set OVERNET_MUTATION=1 to run the mutation gate';
}
if (!eval { require Devel::Mutator::Command::Mutate; require Devel::Mutator::Command::Test; 1 }) {
  plan skip_all => 'Devel::Mutator is not installed (cpanm Devel::Mutator)';
}

my $ROOT = abs_path("$FindBin::Bin/../..");

# An explicit target list is required. Mutating a whole dist would generate
# thousands of mutants and rerun the suite for each, so the operator must name
# the modules under test.
my @targets = grep { length } split /[:\s]+/xms, ($ENV{OVERNET_MUTATION_FILES} // q{});
if (!@targets) {
  plan skip_all => 'set OVERNET_MUTATION_FILES=lib/... (colon- or space-separated) to select modules to mutate';
}
for my $target (@targets) {
  if ($target !~ m{\Alib/}xms || !-f File::Spec->catfile($ROOT, $target)) {
    plan skip_all => "OVERNET_MUTATION_FILES entry is not an existing lib/ file: $target";
  }
}

my $test_command  = $ENV{OVERNET_MUTATION_TEST_COMMAND}  // 'prove -Ilib t';
my $timeout       = $ENV{OVERNET_MUTATION_TIMEOUT}       // 120;
my $max_survivors = $ENV{OVERNET_MUTATION_MAX_SURVIVORS} // 0;

# Never run the mutant suites under coverage instrumentation. It is meaningless
# for mutation testing, and when this template is itself exercised under
# Devel::Cover (e.g. the coverage gate running the contract test that drives
# this template) the child suites would otherwise inherit the instrumentation
# and leak their modules into the parent coverage database.
local $ENV{HARNESS_PERL_SWITCHES} = q{};
local $ENV{PERL5OPT}              = q{};

# Devel::Mutator swaps each mutant file over the real one in place while the
# suite runs and moves it back afterwards; if this process were interrupted
# mid-swap the source tree would be left corrupted. So the whole run happens in
# a throwaway copy of the repo. The copy is placed next to the repo (not in the
# system temp dir) so that sibling-relative paths like ../spec and ../core-perl
# still resolve exactly as they do in a real checkout.
my $parent = abs_path(File::Spec->catdir($ROOT, File::Spec->updir));
my $work   = tempdir('overnet-mutation-XXXXXXXX', DIR => $parent, CLEANUP => 1);

# tar out of the repo (excluding VCS and generated dirs) straight into the copy.
# Run under bash with pipefail (the default /bin/sh is dash, which lacks it) and
# pass the paths as positional args, so a failure in the producing tar is not
# masked by the extracting tar's success and no path is interpolated into the
# shell.
my $copy_status = system 'bash', '-c',
  'set -o pipefail; '
  . 'tar -C "$1" --exclude=.git --exclude=mutants --exclude=cover_db --exclude=blib -cf - . '
  . '| tar -C "$2" -xf -',
  'bash', $ROOT, $work;
is $copy_status, 0, 'copied the repo into an isolated work tree' or bail_out('could not stage a work tree');

# Everything below runs in the copy. Restore the original cwd unconditionally --
# even if Devel::Mutator dies -- so tempdir cleanup does not run from a directory
# that no longer exists.
my $cwd = getcwd();
chdir $work or bail_out("chdir $work: $!");

# Give the run its own empty temp directory. Devel::Mutator tests each mutant
# with `capture { exec ... }` in a forked child; exec means that inner
# Capture::Tiny never cleans up, so it leaks a temp file per mutant, and Test2's
# fixed srand makes File::Temp keep proposing the same names. In a shared /tmp
# already littered with those leftovers, even a tiny run immediately "exceeds the
# maximum number of attempts (1000) to open temp file" and dies. A fresh dir
# inside the (CLEANUP-ed) work tree starts empty every run, so the collisions
# never reach that ceiling for any realistically sized module.
my $mutation_tmp = File::Spec->catdir($work, 'mutation-tmp');
mkdir $mutation_tmp or bail_out("mkdir $mutation_tmp: $!");
local $ENV{TMPDIR} = $mutation_tmp;

# Mutation results are only meaningful against a green suite. If the copied
# suite is already failing -- a wrong OVERNET_MUTATION_TEST_COMMAND, a partial
# copy, or an unrelated failure -- Devel::Mutator would count every mutant as
# "killed" for the wrong reason and report a misleading pass. So establish the
# baseline first, running the command exactly as the mutant runs will.
my ($baseline_out, $baseline_status) = _capture_merged(sub { system $test_command });

my ($mutate_out, $test_out) = (q{}, q{});
my $run_ok    = 1;
my $run_error = q{};
if ($baseline_status == 0) {
  $run_ok = eval {
    ($mutate_out) = _capture_merged(sub {
      Devel::Mutator::Command::Mutate->new(root => q{.})->run(@targets);
    });
    if (($mutate_out =~ /mutants:\s*(\d+)/xms ? $1 : 0) > 0) {
      ($test_out) = _capture_merged(sub {
        Devel::Mutator::Command::Test->new(root => q{.}, command => $test_command, timeout => $timeout)->run;
      });
    }
    1;
  };
  $run_error = $@ if !$run_ok;
}

chdir $cwd or bail_out("chdir $cwd: $!");

my ($mutant_count) = $mutate_out =~ /mutants:\s*(\d+)/xms;
$mutant_count //= 0;
my ($reported_survivors) = $test_out =~ /Result:\s*FAIL\s*\((\d+)\//xms;
$reported_survivors //= 0;
my $timeouts = () = $test_out =~ /[.][.][.]\s+n\/a\s+\(timeout/xmsg;

# Classify survivors against the reviewed-equivalent allowlist.
my $allow_file = $ENV{OVERNET_MUTATION_ALLOW}
  // File::Spec->catfile($ROOT, 'xt', 'author', 'mutation-allow.txt');
my @survivors  = _parse_survivors($test_out);
my %allowed    = _read_allowlist($allow_file);
my @unreviewed = grep { !$allowed{$_} } @survivors;
my $accepted   = @survivors - @unreviewed;

ok $baseline_status == 0, 'the unmutated suite passes (a valid mutation baseline)'
  or diag "Baseline suite is not green; mutation results would be meaningless:\n$baseline_out";

ok $run_ok, 'the mutation run completed without error' or diag $run_error;

ok $mutant_count > 0, "generated mutants for the target modules ($mutant_count mutants)"
  or diag $mutate_out;

# Cross-check our own diff parsing against Devel::Mutator's survivor count, so a
# format drift cannot silently drop survivors from the allowlist comparison.
ok scalar(@survivors) == $reported_survivors,
  "parsed all reported survivors (@{[ scalar @survivors ]} of $reported_survivors)"
  or diag "Could not parse the survivor diffs; raw output:\n$test_out";

ok scalar(@unreviewed) <= $max_survivors,
  sprintf('unreviewed surviving mutants (%d) within the allowed maximum (%d)%s',
  scalar(@unreviewed), $max_survivors, $accepted ? " [$accepted allowlisted]" : q{})
  or diag _survivor_report(\@unreviewed, $allow_file);

ok $timeouts == 0, "no inconclusive (timed-out) mutants ($timeouts)"
  or diag 'Raise OVERNET_MUTATION_TIMEOUT or narrow OVERNET_MUTATION_TEST_COMMAND; a '
  . 'timed-out mutant is neither killed nor counted as a survivor.';

done_testing;

# Capture a block's merged STDOUT+STDERR to a file and return (output, block
# return value) -- a Capture::Tiny::capture_merged replacement that stays sane at
# hundreds of mutants. Devel::Mutator runs each mutant with `capture { exec ... }`
# in a forked child; because exec replaces the process, that inner Capture::Tiny
# never tears down and leaks its temp files, and Test2 seeds srand to a fixed
# value so File::Temp keeps regenerating the same colliding names. Wrapping the
# whole 300-mutant Test loop in an *outer* Capture::Tiny compounds this until the
# temp namespace is exhausted ("exceeded the maximum number of attempts") and the
# run dies mid-flight, corrupting the survivor count. Redirecting the real
# STDOUT/STDERR file descriptors to a plain file with a collision-free name (pid +
# a monotonic counter, created with a plain open, not File::Temp's random names)
# has none of that failure mode, which is what makes the gate reliable.
my $capture_seq = 0;
sub _capture_merged {
  my ($code) = @_;
  my $file = File::Spec->catfile(File::Spec->tmpdir,
    sprintf 'overnet-mutation-cap-%d-%d.out', $$, $capture_seq++);
  open my $save_out, '>&', \*STDOUT or bail_out("dup STDOUT: $!");
  open my $save_err, '>&', \*STDERR or bail_out("dup STDERR: $!");
  open STDOUT, '>', $file or bail_out("open capture file $file: $!");
  open STDERR, '>&', STDOUT or bail_out("merge STDERR into capture: $!");
  my $status;
  my $ok  = eval { $status = $code->(); 1 };
  my $err = $@;
  STDOUT->flush;
  STDERR->flush;
  open STDOUT, '>&', $save_out or bail_out("restore STDOUT: $!");
  open STDERR, '>&', $save_err or bail_out("restore STDERR: $!");
  my $output = q{};
  if (open my $fh, '<', $file) {
    local $/ = undef;
    $output = <$fh>;
    close $fh;
  }
  unlink $file;
  die $err if !$ok;
  return ($output, $status);
}

# A survivor's signature is its changed diff lines (the -/+ lines, minus the
# ---/+++ headers), trailing whitespace stripped. Stable across runs while the
# module's source is unchanged, and human-readable for review.
sub _parse_survivors {
  my ($out) = @_;
  my @lines = split /\n/xms, $out;
  my @signatures;
  my $i = 0;
  while ($i < @lines) {
    if ($lines[$i] !~ m{\A\(\d+/\d+\) .* [.][.][.] \s+ not \s ok \s* \z}xms) {
      $i++;
      next;
    }
    $i++;
    my @change;
    while ($i < @lines
      && $lines[$i] !~ m{\A\(\d+/\d+\)}xms
      && $lines[$i] !~ m{\AResult:}xms) {
      push @change, _trim_right($lines[$i])
        if $lines[$i] =~ /\A[-+]/xms && $lines[$i] !~ /\A(?:---|[+][+][+])/xms;
      $i++;
    }
    push @signatures, join("\n", @change) if @change;
  }
  return @signatures;
}

sub _read_allowlist {
  my ($file) = @_;
  my %allowed;
  return %allowed if !-f $file;
  open my $fh, '<', $file or return %allowed;
  my @block;
  while (my $line = <$fh>) {
    chomp $line;
    if ($line =~ /\A\s*[#]/xms || $line =~ /\A\s*\z/xms) {
      $allowed{ join("\n", @block) } = 1 if @block;
      @block = ();
      next;
    }
    push @block, _trim_right($line) if $line =~ /\A[-+]/xms;
  }
  close $fh or return %allowed;
  $allowed{ join("\n", @block) } = 1 if @block;
  return %allowed;
}

sub _survivor_report {
  my ($unreviewed, $file) = @_;
  return sprintf "%d mutant(s) survived unreviewed. If a survivor is genuinely "
    . "equivalent or\nintentional, add its block (below) to %s after review:\n\n%s\n",
    scalar(@{$unreviewed}), $file, join("\n\n", @{$unreviewed});
}

sub _trim_right {
  my ($line) = @_;
  $line =~ s/\s+\z//xms;
  return $line;
}
