use 5.040;
use strict;
use warnings;

use ExtUtils::MakeMaker;

WriteMakefile(
  NAME               => 'Overnet::Mail',
  VERSION_FROM       => 'lib/Overnet/Mail.pm',
  ABSTRACT_FROM      => 'lib/Overnet/Mail.pm',
  AUTHOR             => 'Overnet Mail contributors',
  LICENSE            => 'gpl_3',
  MIN_PERL_VERSION   => '5.040',
  CONFIGURE_REQUIRES => {
    'ExtUtils::MakeMaker' => '7.10',
  },
  PREREQ_PM => {
    'strictures'         => '2',
    'Moo'                => '2.005005',
    'Email::Simple'      => '2.218',
    'Email::Address::XS' => '1.05',
    'Digest::SHA'        => '0',
  },
  TEST_REQUIRES => {
    'Test2::V0'   => '0',
    'Email::MIME' => '1.954',
  },
  META_MERGE => {
    'meta-spec' => {version => 2},
    resources   => {
      repository => {
        type => 'git',
        url  => 'https://github.com/kestrel-foss-agent/overnet-mail.git',
        web  => 'https://github.com/kestrel-foss-agent/overnet-mail',
      },
      bugtracker => {web => 'https://github.com/kestrel-foss-agent/overnet-mail/issues'},
    },
  },
);
