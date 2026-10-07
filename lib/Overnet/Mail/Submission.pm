package Overnet::Mail::Submission;

use strictures 2;
use Moo;

use Carp          qw(croak);
use Email::Simple ();
use List::Util    qw(min);
use Scalar::Util  qw(blessed);

our $VERSION = '0.001';

has message           => (is => 'ro', required => 1);
has envelope          => (is => 'ro', required => 1);
has max_header_bytes  => (is => 'ro', default  => sub { return 65_536 });
has max_header_fields => (is => 'ro', default  => sub { return 200 });

sub BUILD {
  my ($self) = @_;
  for my $pair ([message => 'Overnet::Mail::RawMessage'], [envelope => 'Overnet::Mail::Envelope']) {
    my ($name, $class) = @{$pair};
    my $value = $self->$name;
    if (!blessed($value) || !$value->isa($class)) {
      croak "$name must be a $class object";
    }
  }
  for my $name (qw(max_header_bytes max_header_fields)) {
    my $limit = $self->$name;
    if (!defined $limit || ref $limit || $limit !~ /\A[1-9][0-9]*\z/smx) {
      croak "$name must be a positive integer";
    }
  }
  my $headers = $self->_checked_headers;
  my $parsed  = Email::Simple->new($headers);
  for my $name ($parsed->header_names) {
    if (lc($name) eq 'bcc' || lc($name) eq 'resent-bcc') {
      croak 'outbound MIME must not contain Bcc or Resent-Bcc headers';
    }
  }
  return;
}

sub _checked_headers {
  my ($self)     = @_;
  my $raw        = $self->message->raw_bytes;
  my $scan_bytes = min(length($raw), $self->max_header_bytes + 4);
  my $prefix     = substr $raw, 0, $scan_bytes;
  my ($headers, $separator) = $prefix =~ /\A(.*?)(\r\n\r\n|\n\n)/smx;
  if (!defined $separator && $scan_bytes < length $raw) {
    croak 'outbound headers exceed max_header_bytes';
  }
  if (!defined $separator || !length $headers) {
    croak 'outbound framing requires headers and an explicit blank separator';
  }
  if (length($headers) > $self->max_header_bytes) {
    croak 'outbound headers exceed max_header_bytes';
  }
  my $newline = $separator eq "\r\n\r\n" ? "\r\n" : "\n";
  my $fields  = 0;
  for my $line (split /\Q$newline\E/smx, $headers, -1) {
    if ($line =~ /[\x00-\x08\x0a-\x1f\x7f]/smx) {
      croak 'unsupported control byte or mixed newline in outbound headers';
    }
    if ($line =~ /\A[\x20\x09]/smx) {
      croak 'orphan outbound header continuation' if !$fields;
      next;
    }
    if ($line !~ /\A[\x21-\x39\x3b-\x7e]+:/smx) {
      croak 'unsupported outbound header field framing';
    }
    ++$fields;
    if ($fields > $self->max_header_fields) {
      croak 'outbound header count exceeds max_header_fields';
    }
  }
  return $headers . $separator;
}

1;

__END__

=head1 NAME

Overnet::Mail::Submission - finalized outbound bytes plus a private envelope

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  my $submission = Overnet::Mail::Submission->new(
    message => $raw_message,
    envelope => $private_envelope,
  );

=head1 DESCRIPTION

Keeps recipient routing separate from immutable visible message bytes. Requires
unambiguous root header framing before inspecting fields with Email::Simple.
Any root Bcc or Resent-Bcc field, including empty or repeated fields, is rejected.
No headers are removed and no bytes are reserialized. Blind recipients belong
only in the envelope; composing finalized MIME is a separate, later operation.

Only the root header block is inspected. Body text and attached messages can
legitimately contain the text Bcc; this class does not sanitize message content.

=head1 SUBROUTINES/METHODS

=head2 BUILD

Moo lifecycle validation callback, invoked automatically during construction.
Callers should construct objects with C<new>, not invoke this callback directly.

=head2 new

Accepts a named-argument list or hash reference with required C<message> and
C<envelope> objects. The objects must be RawMessage and Envelope instances.

=head2 message

Returns the RawMessage object; its original bytes remain unchanged.

=head2 envelope

Returns the private Envelope object, not a recipient-visible header projection.

=head2 max_header_bytes

Returns the configured root-header limit, default 65536 bytes excluding separator.

=head2 max_header_fields

Returns the configured root-field count limit, default 200; folded continuations
do not add fields but do count toward the byte limit.

=head1 DIAGNOSTICS

Unsupported framing, Bcc presence, invalid object types or exceeded limits throw
errors that contain no message data, address values or blind-recipient lists.

=head1 CONFIGURATION AND ENVIRONMENT

The constructor accepts C<max_header_bytes> and C<max_header_fields>.
No environment variables are read.

=head1 DEPENDENCIES

Perl 5.40, strictures 2, Moo, Email::Simple and Scalar::Util.

=head1 INCOMPATIBILITIES

This deliberately narrow outbound subset requires an explicit blank header/body
separator, ASCII field names followed immediately by a colon, and consistent
CRLF or LF header newlines. Bare CR, mixed newlines, orphan continuations and
control bytes are rejected. Header-only messages and obsolete whitespace before
a colon are unsupported here even where RFC 5322 permits them.

=head1 BUGS AND LIMITATIONS

This is a root-header privacy boundary, not full MIME/RFC validity, sender
identity, authentication, deliverability or authorization. Non-ASCII header
values and binary bodies remain opaque bytes; a future transport adapter must
validate SMTPUTF8 separately from 8BITMIME and negotiate required capabilities.
The class does not persist, enqueue, send, normalize or deduplicate anything.

=head1 AUTHOR

Overnet Mail contributors.

=head1 LICENSE AND COPYRIGHT

GPL version 3; see the LICENSE file distributed with this software.

=cut
