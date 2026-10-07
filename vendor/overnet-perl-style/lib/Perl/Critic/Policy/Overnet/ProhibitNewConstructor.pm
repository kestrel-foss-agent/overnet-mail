package Perl::Critic::Policy::Overnet::ProhibitNewConstructor;

use strictures 2;

use Perl::Critic::Utils qw(:severities);
use parent 'Perl::Critic::Policy';

our $VERSION = '0.001';

my $DESC = 'Do not define new constructors directly';
my $EXPL = 'Overnet OO code must let Moo provide constructors instead of defining sub new';

sub default_severity { return $SEVERITY_HIGHEST }
sub default_themes   { return qw(overnet bugs) }
sub applies_to       { return qw(PPI::Statement::Sub PPI::Token::Symbol) }

sub violates {
  my ($self, $element, undef) = @_;

  return if !_defines_new_constructor($element);

  return $self->violation($DESC, $EXPL, $element);
}

sub _defines_new_constructor {
  my ($element) = @_;

  if ($element->isa('PPI::Statement::Sub')) {
    my $name = $element->name;
    return defined $name && $name =~ /(?:\A|::)new\z/smx ? 1 : 0;
  }

  return 0 if $element->content !~ /\A\*(?:[^:]+::)*new\z/smx;
  return _next_significant_content($element) eq q{=} ? 1 : 0;
}

sub _next_significant_content {
  my ($element) = @_;
  my $next = $element->snext_sibling;
  return ref($next) ? $next->content : q{};
}

1;
