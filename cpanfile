requires 'perl', '5.040';
requires 'strictures', '2';
requires 'Moo', '2.005005';
requires 'Email::Simple', '2.218';
requires 'Email::Address::XS', '1.05';
requires 'Digest::SHA';
requires 'DBI', '1.643';
requires 'DBD::Pg', '3.21.2';
requires 'Net::Blossom::Server::Backend::Postgres', '0.001004';
requires 'DBD::SQLite', '1.72';
requires 'JSON', '4.10';
requires 'Net::SMTP', '3.15';
requires 'Net::Blossom::Server::Backend::SQLite', '0.001004';

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
