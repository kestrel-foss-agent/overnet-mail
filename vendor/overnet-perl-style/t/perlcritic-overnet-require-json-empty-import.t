use strictures 2;

use Test2::V0;

use lib 't/lib';

use OvernetPerlCriticPolicyTest qw(has_policy);
use Perl::Critic::Policy::Overnet::RequireJSONEmptyImport;
use Perl::Critic::Utils qw(:severities);

my $json_policy = 'Perl::Critic::Policy::Overnet::RequireJSONEmptyImport';

is $json_policy->default_severity, $SEVERITY_HIGHEST,
  'the Overnet JSON policy defaults to the highest severity';
is [$json_policy->default_themes], [qw(overnet bugs)],
  'the Overnet JSON policy uses the overnet and bugs themes';
is [$json_policy->applies_to], ['PPI::Statement::Include'],
  'the Overnet JSON policy applies to include statements';

ok !has_policy("use strictures 2;\nuse JSON ();\n1;\n", $json_policy),
  'JSON empty import satisfies the Overnet JSON policy';
ok has_policy("use strictures 2;\nuse JSON;\n1;\n", $json_policy),
  'JSON default import violates the Overnet JSON policy';
ok has_policy("use strictures 2;\nuse JSON qw(encode_json);\n1;\n", $json_policy),
  'JSON named import violates the Overnet JSON policy';
ok !has_policy("use strictures 2;\nrequire JSON;\n1;\n", $json_policy),
  'require JSON is ignored by the Overnet JSON policy';

done_testing();
