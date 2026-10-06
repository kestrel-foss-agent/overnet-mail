use strictures 2;

use Test2::V0;

use Test::Perl::Critic (
  -profile  => '.perlcriticrc',
  -severity => 1,
  -only     => 1,
);

all_critic_ok();
