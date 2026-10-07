package Overnet::Mail::Envelope;

use strictures 2;
use Moo;

use Carp               qw(croak);
use Email::Address::XS ();

our $VERSION = '0.001';

has sender            => (is => 'ro', required => 1);
has _recipient_values => (is => 'ro', init_arg => 'recipients', required => 1);
has max_recipients    => (is => 'ro', default  => sub { return 1_000 });
has max_address_bytes => (is => 'ro', default  => sub { return 1_024 });

sub BUILD {
  my ($self) = @_;
  for my $name (qw(max_recipients max_address_bytes)) {
    my $limit = $self->$name;
    if (!defined $limit || ref $limit || $limit !~ /\A[1-9][0-9]*\z/smx) {
      croak "$name must be a positive integer";
    }
  }
  my $recipients = $self->_recipient_values;
  if (ref $recipients ne 'ARRAY' || !@{$recipients}) {
    croak 'recipients must be a nonempty array';
  }
  if (@{$recipients} > $self->max_recipients) {
    croak 'recipient count exceeds max_recipients';
  }
  $self->{sender}            = _address($self->sender, 1, $self->max_address_bytes);
  $self->{_recipient_values} = [map { _address($_, 0, $self->max_address_bytes) } @{$recipients}];
  return;
}

sub recipients {
  my ($self) = @_;
  return [@{$self->_recipient_values}];
}

sub _address {
  my ($value, $allow_null, $limit) = @_;
  if (!defined $value || ref $value) {
    croak 'envelope address must be a scalar string';
  }
  return q{} if $allow_null && $value eq q{};
  if (length($value) > $limit) {
    croak 'envelope address exceeds max_address_bytes';
  }
  if ($value =~ /[^\x20-\x7e]/smx) {
    croak 'envelope addresses must be printable ASCII; SMTPUTF8 is not supported yet';
  }
  my $parsed = Email::Address::XS->parse_bare_address($value);
  if (!$parsed->is_valid) {
    croak 'invalid bare envelope address';
  }
  return $parsed->address;
}

1;

__END__

=head1 NAME

Overnet::Mail::Envelope - recipient-private envelope independent of MIME headers

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  my $envelope = Overnet::Mail::Envelope->new(
    sender => 'Sender@example.test',
    recipients => ['visible@example.test', 'blind@example.test'],
  );

=head1 DESCRIPTION

Holds an SMTP-style envelope separately from message headers. Recipient values
are never inferred from To, Cc or Bcc. Addresses are parsed by Email::Address::XS
and represented using its addr-spec formatter; local-part case is preserved.
No recipient deduplication, routing, mailbox authorization or delivery occurs.

The public interface is read-only and recipient arrays are defensive copies.
As with ordinary Perl objects, direct manipulation of private internals is not
an adversarial-code security boundary.

=head1 SUBROUTINES/METHODS

=head2 BUILD

Moo lifecycle validation callback, invoked automatically during construction.
Callers should construct objects with C<new>, not invoke this callback directly.

=head2 new

Accepts a named-argument list or hash reference. C<sender> and C<recipients> are
required. C<sender =E<gt> ''> is the SMTP null reverse-path; C<E<lt>E<gt>> is not
an addr-spec and is rejected. Empty recipients are never allowed.

=head2 sender

Returns the parsed sender addr-spec, or an empty string for the null reverse-path.

=head2 recipients

Returns a new array reference containing recipient addr-specs in input order,
including duplicates. Keep this list private; it may contain blind recipients.

=head2 max_recipients

Returns the configured positive recipient-count limit, default 1000.

=head2 max_address_bytes

Returns the configured positive address-input limit, default 1024 ASCII bytes.
This resource limit is not a replacement for SMTP path-length constraints.

=head1 DIAGNOSTICS

Invalid types, addresses, empty recipients and exceeded limits throw exceptions.
Errors never include address values or blind-recipient lists.

=head1 CONFIGURATION AND ENVIRONMENT

The constructor accepts C<max_recipients> and C<max_address_bytes>.
No environment variables are read.

=head1 DEPENDENCIES

Perl 5.40, strictures 2, Moo and Email::Address::XS 1.05 or newer.

=head1 INCOMPATIBILITIES

Only printable ASCII envelope addresses are accepted. SMTPUTF8 addresses need a
future explicit capability contract. This restriction does not prohibit encoded
Unicode subjects or MIME bodies, and is not an 8BITMIME capability decision.

=head1 BUGS AND LIMITATIONS

Validation follows the CPAN addr-spec parser, not a claim of complete SMTP
conformance or deliverability. A mature MTA must perform transport validation,
SMTPUTF8/8BITMIME negotiation and policy checks before actual delivery.

=head1 AUTHOR

Overnet Mail contributors.

=head1 LICENSE AND COPYRIGHT

GPL version 3; see the LICENSE file distributed with this software.

=cut
