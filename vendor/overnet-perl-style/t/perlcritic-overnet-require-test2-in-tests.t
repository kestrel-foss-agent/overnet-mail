use strictures 2;

use Test2::V0;

use lib 't/lib';

use OvernetPerlCriticPolicyTest qw(has_policy);
use Perl::Critic::Policy::Overnet::RequireTest2InTests;
use Perl::Critic::Utils qw(:severities);

my $test2_policy = 'Perl::Critic::Policy::Overnet::RequireTest2InTests';

is $test2_policy->default_severity, $SEVERITY_HIGHEST,
  'the Overnet test policy defaults to the highest severity';
is [$test2_policy->default_themes], [qw(overnet tests)],
  'the Overnet test policy uses the overnet and tests themes';
is [$test2_policy->applies_to], ['PPI::Document'],
  'the Overnet test policy applies to whole documents';

ok !has_policy("use strictures 2;\nuse Test2::V0;\n1;\n", $test2_policy, 'sample.t'),
  'Test2::V0 satisfies the Overnet test policy';
ok has_policy("use strictures 2;\nuse Test2::Bundle::Extended;\n1;\n", $test2_policy, 'sample.t'),
  'Test2 modules other than Test2::V0 do not satisfy the Overnet test policy';
ok has_policy("use strictures 2;\nuse Test::More;\n1;\n", $test2_policy, 'sample.t'),
  'Test::More does not satisfy the Overnet test policy';
ok has_policy("use strictures 2;\nuse Test2::V0;\nuse Test::More;\n1;\n", $test2_policy, 'sample.t'),
  'Test::More violates the Overnet test policy even with Test2::V0';
ok has_policy("use strictures 2;\n1;\n", $test2_policy, 'sample.t'),
  'test files without Test2::V0 violate the Overnet test policy';
ok has_policy("use strictures 2;\nuse Test::More;\n1;\n", $test2_policy, 'sample.pl'),
  'Test::More violates the Overnet test policy outside .t files';
ok !has_policy("use strictures 2;\n1;\n", $test2_policy, 'sample.pl'),
  'non-test files are ignored by the Overnet test policy';
ok !has_policy("use strictures 2;\nrequire Test2::V0;\nuse Test2::V0;\n1;\n", $test2_policy, 'sample.t'),
  'require statements are ignored by the Overnet test policy';
ok !has_policy("use strictures 2;\nsub setup {\n  use POSIX ();\n  return 1;\n}\nuse Test2::V0;\n1;\n",
  $test2_policy, 'sample.t'),
  'block-scoped use statements are ignored by the Overnet test policy';

done_testing();
