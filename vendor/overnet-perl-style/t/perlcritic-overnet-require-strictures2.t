use strictures 2;

use Test2::V0;

use lib 't/lib';

use OvernetPerlCriticPolicyTest qw(has_policy);
use Perl::Critic::Policy::Overnet::RequireStrictures2;
use Perl::Critic::Utils qw(:severities);

my $strictures_policy = 'Perl::Critic::Policy::Overnet::RequireStrictures2';

is $strictures_policy->default_severity, $SEVERITY_HIGHEST,
  'the Overnet strictures policy defaults to the highest severity';
is [$strictures_policy->default_themes], [qw(overnet bugs)],
  'the Overnet strictures policy uses the overnet and bugs themes';
is [$strictures_policy->applies_to], ['PPI::Document'],
  'the Overnet strictures policy applies to whole documents';

ok !has_policy("use strictures 2;\n1;\n", $strictures_policy), 'strictures 2 satisfies the Overnet strictures policy';
ok has_policy("use strict;\nuse warnings;\n1;\n", $strictures_policy),
  'strict plus warnings does not satisfy the Overnet strictures policy';
ok has_policy("use strictures;\n1;\n", $strictures_policy),
  'strictures without a version violates the Overnet strictures policy';
ok has_policy("use strictures 1;\n1;\n", $strictures_policy),
  'strictures version 1 violates the Overnet strictures policy';
ok !has_policy("use strict;\nuse warnings;\n1;\n", $strictures_policy, 'Makefile.PL'),
  'Makefile.PL is exempt from the Overnet strictures policy';
ok !has_policy("require POSIX;\nuse strictures 2;\n1;\n", $strictures_policy),
  'require statements are ignored by the Overnet strictures policy';
ok !has_policy("sub load {\n  use POSIX ();\n  return 1;\n}\nuse strictures 2;\n1;\n", $strictures_policy),
  'block-scoped use statements are ignored by the Overnet strictures policy';

done_testing();
