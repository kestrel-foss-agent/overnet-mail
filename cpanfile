requires 'perl', '5.040';
requires 'strictures', '2';

on 'configure' => sub {
  requires 'ExtUtils::MakeMaker', '7.10';
};

on 'test' => sub {
  requires 'Test2::V0';
};

on 'develop' => sub {
  requires 'Devel::Cover';
  requires 'Devel::Mutator';
  requires 'Perl::Critic';
  requires 'Perl::Tidy';
  requires 'Test::Perl::Critic';
  requires 'Test::Pod';
  requires 'Test::Pod::Coverage';
};
