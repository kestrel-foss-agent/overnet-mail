package Overnet::Mail::RawMessage;

use strictures 2;
use Moo;

use Carp        qw(croak);
use Digest::SHA qw(sha256_hex);

our $VERSION = '0.001';

has raw_bytes => (is => 'ro', required => 1);
has max_bytes => (is => 'ro', default  => sub { return 10_485_760 });

sub BUILD {
  my ($self) = @_;
  my $limit = $self->max_bytes;
  if (!defined $limit || ref $limit || $limit !~ /\A[1-9][0-9]*\z/smx) {
    croak 'max_bytes must be a positive integer';
  }
  my $raw = $self->raw_bytes;
  if (!defined $raw || ref $raw || !length $raw) {
    croak 'raw_bytes must be a nonempty octet string';
  }
  if (utf8::is_utf8($raw)) {
    croak 'raw_bytes must be encoded octets, not a character string';
  }
  if (length($raw) > $limit) {
    croak 'raw_bytes exceeds max_bytes';
  }
  return;
}

sub size_bytes {
  my ($self) = @_;
  return length $self->raw_bytes;
}

sub content_sha256 {
  my ($self) = @_;
  return sha256_hex($self->raw_bytes);
}

1;

__END__

=head1 NAME

Overnet::Mail::RawMessage - exact bounded message octets with content identity

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  my $message = Overnet::Mail::RawMessage->new(raw_bytes => $encoded_message);
  my $digest = $message->content_sha256;

=head1 DESCRIPTION

Retains the original scalar octets without parsing, reserializing, unfolding,
normalizing newlines or decoding MIME. The public API is read-only; callers
receive scalar values, not references to the stored data. Incoming content may
retain Bcc or malformed MIME as opaque bytes. Outbound acceptance is separate.

Content identity is SHA-256 of the exact bytes. It is not RFC Message-ID, an
outbox idempotency key, an authorization token or a delivery uniqueness claim.
Messages without Message-ID are accepted, and duplicate Message-ID values are
not treated as duplicates.

=head1 SUBROUTINES/METHODS

=head2 BUILD

Moo lifecycle validation callback, invoked automatically during construction.
Callers should construct objects with C<new>, not invoke this callback directly.

=head2 new

Accepts a named-argument list or hash reference. C<raw_bytes> is required and must
be a nonempty scalar octet string. Perl character strings with the UTF-8 flag
must be explicitly encoded before construction, even if they contain ASCII.

=head2 raw_bytes

Returns the original immutable-by-public-interface octets.

=head2 size_bytes

Returns the byte length of the original content.

=head2 content_sha256

Returns its lowercase hexadecimal SHA-256 digest.

=head2 max_bytes

Returns the configured positive size limit, default 10485760 bytes (10 MiB).

=head1 DIAGNOSTICS

Invalid types, character strings and exceeded limits throw value-free errors.

=head1 CONFIGURATION AND ENVIRONMENT

The constructor accepts C<max_bytes>. No environment variables are read.

=head1 DEPENDENCIES

Perl 5.40, strictures 2, Moo and Digest::SHA.

=head1 INCOMPATIBILITIES

No implicit character encoding conversion is performed.

=head1 BUGS AND LIMITATIONS

This object provides neither persistence nor MIME/RFC validation. Direct changes
to private Perl object internals are outside the read-only API contract. Header,
attachment and transport processing require their own bounded validation.

=head1 AUTHOR

Overnet Mail contributors.

=head1 LICENSE AND COPYRIGHT

GPL version 3; see the LICENSE file distributed with this software.

=cut
