use strictures 2;

use Test2::V0;

use lib 't/lib';

use OvernetPerlCriticPolicyTest qw(has_policy);
use Perl::Critic::Policy::Overnet::ProhibitBless;
use Perl::Critic::Utils qw(:severities);

my $bless_policy = 'Perl::Critic::Policy::Overnet::ProhibitBless';

is $bless_policy->default_severity, $SEVERITY_HIGHEST,
  'the Overnet bless policy defaults to the highest severity';
is [$bless_policy->default_themes], [qw(overnet bugs)],
  'the Overnet bless policy uses the overnet and bugs themes';
is [$bless_policy->applies_to], [qw(PPI::Token::Word PPI::Token::Symbol)],
  'the Overnet bless policy applies to word and symbol tokens';

ok !has_policy("use strictures 2;\nuse Moo;\n1;\n", $bless_policy),
  'Moo classes satisfy the Overnet bless policy';
ok has_policy("use strictures 2;\nsub build { return bless {}, shift; }\n1;\n", $bless_policy),
  'bare bless violates the Overnet bless policy';
ok has_policy("use strictures 2;\nsub build { return CORE::bless {}, shift; }\n1;\n", $bless_policy),
  'CORE::bless violates the Overnet bless policy';
ok has_policy("use strictures 2;\nsub build { return &bless({}, shift); }\n1;\n", $bless_policy),
  'ampersand bless violates the Overnet bless policy';
ok has_policy("use strictures 2;\nsub build { return &CORE::bless({}, shift); }\n1;\n", $bless_policy),
  'ampersand CORE::bless violates the Overnet bless policy';
ok !has_policy("use strictures 2;\nuse Scalar::Util qw(blessed);\nsub check { return blessed(\$_[0]); }\n1;\n",
  $bless_policy),
  'calling blessed does not violate the Overnet bless policy';
ok !has_policy("use strictures 2;\nmy \$value = 'bless';\n# bless should not matter in comments\n1;\n",
  $bless_policy),
  'bless in strings and comments does not violate the Overnet bless policy';
ok !has_policy("use strictures 2;\nmy %dispatch = (bless => sub { return 1; });\n1;\n", $bless_policy),
  'bless as a hash key does not violate the Overnet bless policy';
ok !has_policy("use strictures 2;\nsub apply { return \$_[0]->bless; }\n1;\n", $bless_policy),
  'bless method calls do not violate the Overnet bless policy';
ok has_policy("use strictures 2;\nbless", $bless_policy),
  'bare bless with nothing following still violates the Overnet bless policy';

done_testing();
