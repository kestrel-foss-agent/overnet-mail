package Perl::Critic::Policy::Overnet::RequireMooConstructorArgsNormalization;

use strictures 2;

use List::Util          qw(any);
use Perl::Critic::Utils qw(:severities);
use Scalar::Util        qw(refaddr);
use parent 'Perl::Critic::Policy';

our $VERSION = '0.001';

my $DESC = 'Normalize Moo constructor arguments before using %args';
my $EXPL =
"Moo constructors must preserve the documented hashref form, so BUILDARGS and around new wrappers must capture \@_ as \@args before normalization";

sub default_severity { return $SEVERITY_HIGHEST }
sub default_themes   { return qw(overnet bugs) }
sub applies_to       { return qw(PPI::Statement::Sub PPI::Statement) }

sub violates {
  my ($self, $element, undef) = @_;

  my $block;
  if ($element->isa('PPI::Statement::Sub')) {
    return
      if !((defined $element->name && $element->name eq 'BUILDARGS'));
    $block = _first_block($element);
  } else {
    return if !_is_around_new_statement($element);
    $block = _first_block($element);
  }

  return if !$block;

  my $bad_statement = _first_bad_args_statement($block, $element);
  return if !$bad_statement;

  return $self->violation($DESC, $EXPL, $bad_statement);
}

sub _is_around_new_statement {
  my ($statement) = @_;

  my @children = _significant_children($statement);
  return 0 if @children < 2;
  return 0
    if !($children[0]->isa('PPI::Token::Word') && $children[0]->content eq 'around');

  return _is_new_target($children[1]);
}

sub _is_new_target {
  my ($token) = @_;

  return 1 if $token->isa('PPI::Token::Word')  && $token->content eq 'new';
  return 1 if $token->isa('PPI::Token::Quote') && $token->string eq 'new';
  return 1 if _constructor_contains_new_target($token);

  return 0;
}

sub _constructor_contains_new_target {
  my ($token) = @_;

  return 0 if !$token->isa('PPI::Structure::Constructor');

  my $targets = $token->find(
    sub {
      my (undef, $element) = @_;
      return _is_literal_new_target($element);
    }
  ) || [];

  return @{$targets} ? 1 : 0;
}

sub _is_literal_new_target {
  my ($element) = @_;

  return 1
    if $element->isa('PPI::Token::Word') && $element->content eq 'new';
  return 1
    if $element->isa('PPI::Token::Quote') && $element->string eq 'new';
  return 1
    if $element->isa('PPI::Token::QuoteLike::Words')
    && any { $_ eq 'new' } $element->literal;

  return 0;
}

sub _first_block {
  my ($element) = @_;
  return $element->find_first('PPI::Structure::Block');
}

sub _first_bad_args_statement {
  my ($block, $context) = @_;

  my $statements = $block->find('PPI::Statement::Variable') || [];
  for my $statement (@{$statements}) {
    next if _inside_nested_sub($statement, $context, $block);
    return $statement
      if _assigns_raw_at_underscore_to_hash_args($statement);
  }

  return;
}

sub _inside_nested_sub {
  my ($statement, $context, $root_block) = @_;

  my $context_id    = refaddr($context);
  my $root_block_id = refaddr($root_block);

  my $node = $statement->parent;
  while ($node) {
    return 0 if refaddr($node) == $context_id;

    return 1 if $node->isa('PPI::Statement::Sub');
    return 1
      if $node->isa('PPI::Structure::Block')
      && refaddr($node) != $root_block_id
      && _block_is_anonymous_sub_body($node);

    $node = $node->parent;
  }

  return 0;
}

sub _block_is_anonymous_sub_body {
  my ($block) = @_;

  my $previous = $block->sprevious_sibling;
  return
       ref($previous)
    && $previous->isa('PPI::Token::Word')
    && $previous->content eq 'sub' ? 1 : 0;
}

sub _assigns_raw_at_underscore_to_hash_args {
  my ($statement) = @_;

  my @tokens = _significant_tokens($statement);
  return 0 if !@tokens;
  return 0
    if !($tokens[0]->isa('PPI::Token::Word') && $tokens[0]->content eq 'my');

  my $assignment_index;
  for my $index (0 .. $#tokens) {
    if ( $tokens[$index]->isa('PPI::Token::Operator')
      && $tokens[$index]->content eq q{=}) {
      $assignment_index = $index;
      last;
    }
  }
  return 0 if !defined $assignment_index;

  my @lhs_tokens = @tokens[1 .. $assignment_index - 1];
  my @rhs_tokens = @tokens[$assignment_index + 1 .. $#tokens];

  return 0
    if !any { $_->isa('PPI::Token::Symbol') && $_->content eq '%args' } @lhs_tokens;
  return 0
    if !any { $_->isa('PPI::Token::Magic') && $_->content eq "\@_" } @rhs_tokens;

  return 1;
}

sub _significant_children {
  my ($element) = @_;
  return grep { !_is_insignificant($_) } $element->children;
}

sub _significant_tokens {
  my ($element) = @_;
  my $tokens = $element->find(
    sub {
      my (undef, $token) = @_;
      return $token->isa('PPI::Token') && !_is_insignificant($token);
    }
  ) || [];
  return @{$tokens};
}

sub _is_insignificant {
  my ($element) = @_;
  return $element->isa('PPI::Token::Whitespace')
    || $element->isa('PPI::Token::Comment') ? 1 : 0;
}

1;
