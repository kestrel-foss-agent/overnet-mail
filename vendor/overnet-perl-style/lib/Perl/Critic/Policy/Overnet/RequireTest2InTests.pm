package Perl::Critic::Policy::Overnet::RequireTest2InTests;

use strictures 2;

use Perl::Critic::Utils qw(:severities);
use parent 'Perl::Critic::Policy';

our $VERSION = '0.001';

my $DESC = 'Use Test2::V0';
my $EXPL = 'Overnet Perl test files must use Test2::V0 and must not use Test::More';

sub default_severity { return $SEVERITY_HIGHEST }
sub default_themes   { return qw(overnet tests) }
sub applies_to       { return 'PPI::Document' }

sub violates {
  my ($self, undef, $document) = @_;

  my $includes = $document->find('PPI::Statement::Include') || [];
  for my $include (@{$includes}) {
    next if ($include->type || q{}) ne 'use';
    return $self->violation($DESC, $EXPL, $include)
      if (($include->module || q{}) eq 'Test::More');
  }

  my $filename = $document->filename || q{};
  return if $filename !~ /[.]t\z/smx;

  for my $include (@{$includes}) {
    next   if !$include->parent->isa('PPI::Document');
    next   if ($include->type || q{}) ne 'use';
    return if (($include->module || q{}) eq 'Test2::V0');
  }

  return $self->violation($DESC, $EXPL, _first_statement_or_document($document));
}

sub _first_statement_or_document {
  my ($document) = @_;
  my $statements = $document->find('PPI::Statement') || [];
  return $statements->[0] || $document;
}

1;
