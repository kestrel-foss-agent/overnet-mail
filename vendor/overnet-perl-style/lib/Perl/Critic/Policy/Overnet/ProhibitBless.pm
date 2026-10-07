package Perl::Critic::Policy::Overnet::ProhibitBless;

use strictures 2;

use Perl::Critic::Utils qw(:severities);
use parent 'Perl::Critic::Policy';

our $VERSION = '0.001';

my $DESC = 'Do not use bless directly';
my $EXPL = 'Overnet OO code must use Moo-owned construction instead of hand-rolled blessed objects';

sub default_severity { return $SEVERITY_HIGHEST }
sub default_themes   { return qw(overnet bugs) }
sub applies_to       { return qw(PPI::Token::Word PPI::Token::Symbol) }

sub violates {
  my ($self, $token, undef) = @_;

  return if !_is_direct_bless($token);

  return $self->violation($DESC, $EXPL, $token);
}

sub _is_direct_bless {
  my ($token) = @_;
  my $content = $token->content;

  if ($token->isa('PPI::Token::Symbol')) {
    return $content =~ /\A&(?:CORE::)?bless\z/smx ? 1 : 0;
  }

  return 0 if $content !~ /\A(?:CORE::)?bless\z/smx;
  return 0 if _previous_significant_content($token) eq '->';
  return 0 if _next_significant_content($token) eq '=>';

  return 1;
}

sub _previous_significant_content {
  my ($element) = @_;
  my $previous = $element->sprevious_sibling;
  return ref($previous) ? $previous->content : q{};
}

sub _next_significant_content {
  my ($element) = @_;
  my $next = $element->snext_sibling;
  return ref($next) ? $next->content : q{};
}

1;
