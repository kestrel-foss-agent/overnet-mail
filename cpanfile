requires 'perl', '5.040';
requires 'strictures', '2';
requires 'Moo', '2.005005';
requires 'Email::Simple', '2.218';
requires 'Email::Address::XS', '1.05';
requires 'Digest::SHA';

on 'configure' => sub {
  requires 'ExtUtils::MakeMaker', '7.10';
};

on 'test' => sub {
  requires 'Test2::V0';
  requires 'Email::MIME', '1.954';
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
