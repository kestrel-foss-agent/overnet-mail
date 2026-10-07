use strictures 2;

use Test2::V0;

use lib 't/lib';

use OvernetPerlCriticPolicyTest qw(has_policy);
use Perl::Critic::Policy::Overnet::RequireMooConstructorArgsNormalization;
use Perl::Critic::Utils qw(:severities);

my $policy =
  'Perl::Critic::Policy::Overnet::RequireMooConstructorArgsNormalization';

is $policy->default_severity, $SEVERITY_HIGHEST,
  'the constructor args policy defaults to the highest severity';
is [ $policy->default_themes ], [qw(overnet bugs)],
  'the constructor args policy uses the overnet and bugs themes';
is [ $policy->applies_to ], [qw(PPI::Statement::Sub PPI::Statement)],
  'the constructor args policy applies to sub statements and statements';

ok !has_policy(
"use strictures 2;\nuse Moo;\nsub BUILDARGS {\n  my (\$class, \@args) = \@_;\n  my %args = _constructor_args_hash(\@args);\n  return \\%args;\n}\n1;\n",
    $policy,
  ),
  'BUILDARGS may capture raw constructor args as @args';

ok !has_policy(
"use strictures 2;\nuse Moo;\nsub BUILDARGS {\n  my \$class = shift;\n  my \@args = \@_;\n  return _normalize(\@args);\n}\n1;\n",
    $policy,
  ),
  'BUILDARGS may shift class and preserve remaining args as @args';

ok !has_policy(
"use strictures 2;\nuse Moo;\naround new => sub {\n  my (\$orig, \$class, \@args) = \@_;\n  my %args = _constructor_args_hash(\@args);\n  return \$class->SUPER::new(%args);\n};\n1;\n",
    $policy,
  ),
  'around new may capture raw constructor args as @args';

ok !has_policy(
"use strictures 2;\nsub helper {\n  my (\$class, %args) = \@_;\n  return \\%args;\n}\n1;\n",
    $policy,
  ),
  'non-constructor methods may use %args';

ok !has_policy(
"use strictures 2;\nuse Moo;\nsub BUILDARGS {\n  my (\$class, \@args) = \@_;\n  my %args = \@args;\n  return \\%args;\n}\n1;\n",
    $policy,
  ),
  'normalized @args may be converted to %args later';

ok !has_policy(
"use strictures 2;\nuse Moo;\nsub BUILDARGS {\n  my (\$class, \@args) = \@_;\n  my \$helper = sub {\n    my %args = \@_;\n    return \\%args;\n  };\n  return _normalize(\@args);\n}\n1;\n",
    $policy,
  ),
'nested helper closures inside BUILDARGS are not constructor arg normalization';

ok has_policy(
"use strictures 2;\nuse Moo;\nsub BUILDARGS {\n  my (\$class, %args) = \@_;\n  return \\%args;\n}\n1;\n",
    $policy,
  ),
  'BUILDARGS must not destructure @_ directly into %args';

ok has_policy(
"use strictures 2;\nuse Moo;\nsub BUILDARGS {\n  my %args = \@_;\n  return \\%args;\n}\n1;\n",
    $policy,
  ),
  'BUILDARGS must not assign @_ directly into %args';

ok has_policy(
"use strictures 2;\nuse Moo;\nsub BUILDARGS {\n  my \$class = shift;\n  my %args = \@_;\n  return \\%args;\n}\n1;\n",
    $policy,
  ),
  'BUILDARGS must not shift class and assign remaining @_ directly into %args';

ok has_policy(
"use strictures 2;\nuse Moo;\nsub BUILDARGS {\n  shift;\n  my %args = \@_;\n  return \\%args;\n}\n1;\n",
    $policy,
  ),
  'BUILDARGS must not use implicit shift then direct %args assignment';

ok has_policy(
"use strictures 2;\nuse Moo;\naround new => sub {\n  my (\$orig, \$class, %args) = \@_;\n  return \$class->SUPER::new(%args);\n};\n1;\n",
    $policy,
  ),
  'around new must not destructure @_ directly into %args';

ok has_policy(
"use strictures 2;\nuse Moo;\naround new => sub {\n  my \$orig = shift;\n  my \$class = shift;\n  my %args = \@_;\n  return \$class->SUPER::new(%args);\n};\n1;\n",
    $policy,
  ),
'around new must not shift wrapper args and assign remaining @_ directly into %args';

ok has_policy(
"use strictures 2;\nuse Moo;\naround 'new' => sub {\n  my (\$orig, \$class, %args) = \@_;\n  return \$class->SUPER::new(%args);\n};\n1;\n",
    $policy,
  ),
  'quoted around new is covered';

ok has_policy(
"use strictures 2;\nuse Moo;\naround [qw(new close)] => sub {\n  my (\$orig, \$class, %args) = \@_;\n  return \$class->SUPER::new(%args);\n};\n1;\n",
    $policy,
  ),
  'arrayref around new is covered';

ok !has_policy(
"use strictures 2;\nmy \$sample = 'my (\$class, %args) = \@_';\n# sub BUILDARGS { my %args = \@_; }\n1;\n",
    $policy,
  ),
  'strings and comments do not violate the constructor args policy';

ok !has_policy(
    "use strictures 2;\nuse Moo;\nsub BUILDARGS;\n1;\n",
    $policy,
  ),
  'BUILDARGS forward declarations have no block to inspect';

ok !has_policy(
"use strictures 2;\nuse Moo;\naround [qw(open close)] => sub {\n  my (\$orig, \$class, %args) = \@_;\n  return \$class->\$orig(%args);\n};\n1;\n",
    $policy,
  ),
  'around wrappers for methods other than new may use %args';

ok has_policy(
"use strictures 2;\nuse Moo;\naround [ new ] => sub {\n  my (\$orig, \$class, %args) = \@_;\n  return \$class->\$orig(%args);\n};\n1;\n",
    $policy,
  ),
  'bareword arrayref around new is covered';

ok has_policy(
"use strictures 2;\nuse Moo;\naround [ 'new' ] => sub {\n  my (\$orig, \$class, %args) = \@_;\n  return \$class->\$orig(%args);\n};\n1;\n",
    $policy,
  ),
  'quoted arrayref around new is covered';

ok !has_policy(
"use strictures 2;\nuse Moo;\nmy \$method = 'new';\naround \$method => sub {\n  my (\$orig, \$class, %args) = \@_;\n  return \$class->\$orig(%args);\n};\n1;\n",
    $policy,
  ),
  'dynamic around targets are not treated as constructor wrappers';

ok !has_policy(
"use strictures 2;\nuse Moo;\nsub BUILDARGS {\n  my (\$class, \@args) = \@_;\n  sub _args_hash {\n    my %args = \@_;\n    return \\%args;\n  }\n  return _normalize(\@args);\n}\n1;\n",
    $policy,
  ),
  'nested named subs inside BUILDARGS are not constructor arg normalization';

ok !has_policy(
"use strictures 2;\nuse Moo;\nsub BUILDARGS {\n  our %args = \@_;\n  return \\%args;\n}\n1;\n",
    $policy,
  ),
  'only my declarations of %args are treated as normalization bypasses';

ok !has_policy(
"use strictures 2;\nuse Moo;\nsub BUILDARGS {\n  my (\$class, \@args) = \@_;\n  my %args;\n  return _normalize(\@args, \\%args);\n}\n1;\n",
    $policy,
  ),
  'declarations of %args without an assignment are allowed';

ok !has_policy(
"use strictures 2;\nuse Moo;\naround configure => sub {\n  my (\$orig, \$class, %args) = \@_;\n  return \$class->\$orig(%args);\n};\n1;\n",
    $policy,
  ),
  'around wrappers for non-new barewords may use %args';

ok !has_policy(
"use strictures 2;\nuse Moo;\nbefore new => sub {\n  my (\$orig, \$class, %args) = \@_;\n  return;\n};\n1;\n",
    $policy,
  ),
  'before new modifiers are not treated as constructor wrappers';

ok !has_policy(
"use strictures 2;\nuse Moo;\naround [ close ] => sub {\n  my (\$orig, \$class, %args) = \@_;\n  return \$class->\$orig(%args);\n};\n1;\n",
    $policy,
  ),
  'bareword arrayref around a non-new method is not covered';

ok !has_policy(
"use strictures 2;\nuse Moo;\nsub BUILDARGS {\n  my (\$class, \@args) = \@_;\n  my \$count = %args + \@_;\n  return {};\n}\n1;\n",
    $policy,
  ),
  'the %args symbol must be on the assignment left-hand side to violate';

ok !has_policy(
"use strictures 2;\nuse Moo;\nsub BUILDARGS {\n  my %args = (name => \$0);\n  return \\%args;\n}\n1;\n",
    $policy,
  ),
  'assigning %args from magic vars other than \@_ is not a normalization bypass';

ok has_policy(
"use strictures 2;\nuse Moo;\nsub BUILDARGS {\n  do {\n    my %args = \@_;\n  };\n  return {};\n}\n1;\n",
    $policy,
  ),
  'direct %args assignment inside a do block still violates';

done_testing();
