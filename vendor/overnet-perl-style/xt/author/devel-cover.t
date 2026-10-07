use strictures 2;

use Cwd            qw(abs_path);
use File::Basename qw(dirname);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Test2::V0;

# Coverage collection is slow and needs Devel::Cover, so it is opt-in: it runs
# only when OVERNET_COVERAGE is set (a coverage CI job sets it). A normal
# `prove xt/author/` run skips it.
if (!$ENV{OVERNET_COVERAGE}) {
  plan skip_all => 'set OVERNET_COVERAGE=1 to run the coverage gate';
}
if (!eval { require Devel::Cover; require Devel::Cover::DB; 1 }) {
  plan skip_all => 'Devel::Cover is not installed';
}

my $ROOT  = abs_path("$FindBin::Bin/../..");
my $PERL  = $^X;
my $PROVE = _tool('prove');

# Per-file floors for everything under lib/. The floors are deliberately high:
# an uncalled subroutine is a missing test or dead code, and the statement and
# branch allowances exist only for defensive paths that need fault injection
# to reach. This template is synced verbatim across repos, so repos tune the
# floors through the environment instead of editing the file: a repo below a
# floor pins its current watermark in its coverage CI job and raises it as
# tests improve, never lowering it.
my %MIN = (
  statement  => $ENV{OVERNET_COVERAGE_MIN_STATEMENT}  // 95,
  branch     => $ENV{OVERNET_COVERAGE_MIN_BRANCH}     // 85,
  subroutine => $ENV{OVERNET_COVERAGE_MIN_SUBROUTINE} // 100,
);

chdir $ROOT or die "chdir $ROOT: $!";

my $db_dir = File::Spec->catdir(tempdir(CLEANUP => 1), 'cover_db');

# -blib,0 stops Devel::Cover from doing an implicit "use blib" when a stale
# blib/ directory is lying around from a previous make: that would put
# blib/lib ahead of lib/ on @INC, so the suite would exercise and record the
# stale built copies and every row would escape the lib/ filter below.
my $switches = "-MDevel::Cover=-db,$db_dir,-silent,1,-blib,0";

my @tests = sort glob 't/*.t';
ok scalar(@tests), 'found test files to run under coverage' or bail_out('no tests to cover');

{
  # Collect every criterion; restricting collection to a subset skews branch
  # data. The report step below is what filters to the metrics we gate on.
  # PERL5LIB is inherited so sibling repo libs stay visible to the suite.
  local $ENV{HARNESS_PERL_SWITCHES} = $switches;
  my $status = system $PERL, $PROVE, '-Ilib', @tests;
  is $status, 0, 'the test suite passes under coverage instrumentation';
}

# Require every module under lib/ in one instrumented process. A module the
# suite never loads would otherwise produce no coverage rows at all and
# silently escape the gate; loading it records its statements and
# subroutines as uncovered so the floors below judge it like everything else.
my $loader = <<'LOADER';
my @modules;
File::Find::find(sub { push @modules, $File::Find::name if /[.]pm\z/xms }, 'lib');
my $failed = 0;
for my $file (sort @modules) {
  (my $rel = $file) =~ s{\Alib/}{}xms;
  if (!eval { require $rel; 1 }) {
    $failed = 1;
    print {*STDERR} "failed to load $file: $@";
  }
}
exit $failed;
LOADER

{
  my $status = system $PERL, '-Ilib', $switches, '-MFile::Find', '-e', $loader;
  is $status, 0, 'every module under lib/ loads under coverage instrumentation';
}

my %coverage = _read_coverage($db_dir);
ok scalar(keys %coverage), 'coverage was collected for lib/'
  or bail_out('no lib/ coverage rows were produced');

for my $file (sort keys %coverage) {
  for my $metric (sort keys %MIN) {
    my $got   = $coverage{$file}{$metric};
    my $shown = $got // 'missing';
    ok defined($got) && $got >= $MIN{$metric}, "$file: $metric coverage $shown% >= $MIN{$metric}%"
      or diag "coverage shortfall in $file for $metric";
  }
}

done_testing;

sub _tool {
  my ($name) = @_;
  my $beside = File::Spec->catfile(dirname($PERL), $name);
  return -x $beside ? $beside : $name;
}

sub _read_coverage {
  my ($dir) = @_;

  # Read the database directly instead of parsing `cover -summary` output,
  # which truncates long file names and would silently drop files from the
  # gate. Only lib/ modules are gated; the suite's own t/ files are not.
  my $db = Devel::Cover::DB->new(db => $dir);
  $db = $db->merge_runs;
  $db->calculate_summary(statement => 1, branch => 1, subroutine => 1);

  my %seen;
  for my $file (grep { m{\Alib/}xms } $db->cover->items) {
    $seen{$file} = { map { $_ => _percentage($db, $file, $_) } qw(statement branch subroutine) };
  }
  return %seen;
}

sub _percentage {
  my ($db, $file, $metric) = @_;
  my $value = $db->summary($file, $metric, 'percentage');

  # A file with no branches has no branch percentage; treat that as covered.
  return defined $value ? 0 + sprintf('%.1f', $value) : 100;
}
