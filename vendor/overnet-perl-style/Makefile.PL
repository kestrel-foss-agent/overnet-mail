use 5.040;
use strict;
use warnings;

use ExtUtils::MakeMaker;

WriteMakefile(
  NAME             => 'Overnet::Perl::Style',
  VERSION          => '0.001',
  MIN_PERL_VERSION => '5.040',
  LICENSE          => 'gpl_3',
  PREREQ_PM        => {
    'Perl::Critic'        => 0,
    'Perl::Tidy'          => 0,
    'Test::Perl::Critic'  => 0,
    'Test::Pod'           => 0,
    'Test::Pod::Coverage' => 0,
    'strictures'          => 0,
  },
);
