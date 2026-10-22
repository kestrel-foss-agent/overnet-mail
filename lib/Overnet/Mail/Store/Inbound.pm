package Overnet::Mail::Store::Inbound;

use strictures 2;
use Moo::Role;

use Carp               qw(croak);
use Digest::SHA        qw(sha256_hex);
use Email::Address::XS ();
use JSON               ();
use Overnet::Mail::Envelope;

our $VERSION = '0.001';

requires qw(_dbh _transaction _mailbox_state _receipt_message _receive_message);

sub _deploy_recipient_routes {
  my ($self) = @_;
  $self->_dbh->do(<<'ROUTES');
CREATE TABLE recipient_routes (
      recipient TEXT NOT NULL PRIMARY KEY,
      mailbox_id TEXT NOT NULL REFERENCES mailboxes(mailbox_id)
)
ROUTES
  return;
}

sub register_recipient {
  my ($self, %args) = @_;
  _routing_token($args{mailbox_id});
  my $recipient = _recipient($args{recipient});
  return $self->_transaction(
    sub {
      my $dbh = $self->_dbh;
      my $existing =
        $dbh->selectrow_array('SELECT mailbox_id FROM recipient_routes WHERE recipient = ?', undef, $recipient);
      if (defined $existing) {
        croak 'recipient route already belongs to another mailbox' if $existing ne $args{mailbox_id};
      } else {
        croak 'recipient route requires an existing mailbox' if !$self->_mailbox_state($args{mailbox_id});
        $dbh->do('INSERT INTO recipient_routes (recipient, mailbox_id) VALUES (?, ?)',
          undef, $recipient, $args{mailbox_id});
      }
      return {recipient => $recipient, mailbox_id => $args{mailbox_id}};
    }
  );
}

sub receive_delivery {
  my ($self, %args) = @_;

  # A transport cannot override the recipient route or receipt namespace.
  my %allowed = map { $_ => 1 } qw(source_id idempotency_key recipient message received_at);
  for my $name (keys %args) {
    croak 'unsupported inbound delivery argument' if !$allowed{$name};
  }
  _routing_token($args{source_id});
  my $recipient = _recipient($args{recipient});
  my $message   = $self->_receipt_message(\%args);

  # Force string encoding so Perl numeric flags cannot split a token identity.
  my $namespace = sha256_hex(JSON->new->encode([q{} . $args{source_id}, $recipient]));
  return $self->_transaction(
    sub {
      my $mailbox =
        $self->_dbh->selectrow_array('SELECT mailbox_id FROM recipient_routes WHERE recipient = ?', undef, $recipient);
      return {status => 'unknown_recipient'}                   if !defined $mailbox;
      croak 'stored recipient route refers to missing mailbox' if !$self->_mailbox_state($mailbox);
      my $receipt = $self->_receive_message({%args, mailbox_id => $mailbox}, $message, $namespace);
      return {status => 'received', receipt => $receipt};
    }
  );
}

sub _recipient {
  my ($value) = @_;

  # Reuse the maintained envelope parser and its ASCII/input-size contract.
  my $envelope = Overnet::Mail::Envelope->new(sender => q{}, recipients => [$value]);
  my $parsed   = Email::Address::XS->parse_bare_address($envelope->recipients->[0]);
  $parsed->host(lc $parsed->host);
  return $parsed->address;
}

sub _routing_token {
  my ($value) = @_;
  if (!defined $value || ref $value || $value !~ /\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z/smx) {
    croak 'routing identity must be a bounded ASCII token';
  }
  return;
}

1;

__END__

=head1 NAME

Overnet::Mail::Store::Inbound - trusted local recipient routing and durable custody

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  $store->ensure_mailbox(mailbox_id => 'alice');
  $store->register_recipient(recipient => 'alice@example.test', mailbox_id => 'alice');
  my $result = $store->receive_delivery(
    source_id => 'local-mta', idempotency_key => 'queue-id-123',
    recipient => 'alice@example.test', message => $raw_message, received_at => 100,
  );

=head1 DESCRIPTION

Composed into both Store engines. Explicit, append-only address routes select an
existing authoritative mailbox. Route lookup and receipt acceptance share one
serialized transaction. This is an adapter-facing trusted local boundary, not
an SMTP/LMTP server, authentication service or account provisioning design.

=head1 SUBROUTINES/METHODS

=head2 register_recipient

Requires C<recipient> and an already-created C<mailbox_id>. Parses the address
using the existing Envelope contract and lowercases only its domain. Local-part
case remains significant. No plus-tag stripping, wildcard, catch-all, forwarding
or header-derived routing occurs. Returns C<recipient> and C<mailbox_id> after
commit. Repeating the same binding is idempotent; any rebind throws. Multiple
explicit addresses may target one mailbox. No route removal or mutation exists.
This administrative API requires a trusted caller; it does not authorize users.

=head2 receive_delivery

Requires C<source_id>, C<idempotency_key>, C<recipient>, C<message> (RawMessage)
and C<received_at>. Source IDs use bounded ASCII tokens, like receipt keys.
Unsupported arguments, including C<mailbox_id>, are rejected. Message, size,
timestamp and identity validation also applies to unknown recipients and replays.

An unknown address returns only C<< {status =E<gt> 'unknown_recipient'} >> without
creating a mailbox, bytes, receipt or outbox. A known address returns only
C<< {status =E<gt> 'received', receipt =E<gt> $receipt} >> after Store's durable
commit and cleanup. The nested receipt is the unchanged existing recipient
receipt shape, with no recipient, mailbox selector or private envelope.

Replay identity comprises the source, canonical recipient and delivery key.
The namespace is SHA-256 of the JSON-encoded source/recipient string tuple; the
key is compared separately by SQL. Direct C<receive_message> always uses a
disjoint namespace. All previously valid direct keys remain valid. Distinct
aliases, sources or keys yield distinct receipts; content is shared. Exact
replay retains the first timestamp and UID. Changed bytes fail closed.

The upstream adapter must retain a stable source/key across retries, including
lost acknowledgements, and must not reuse a key for another delivery. A new key
means a new delivery even for identical bytes. The library cannot deduplicate an
upstream peer that loses its queue identity. Immutable bindings prevent a retry
from silently moving to a new mailbox. Direct SQL changes are outside this
trusted boundary. Neither route existence nor a mailbox ID is a credential.

=head1 CONFIGURATION AND ENVIRONMENT

No environment configuration, listener, login or network transport is created.
Use explicit trusted calls to provision synthetic routes for the local lab.

=head1 DIAGNOSTICS

Unknown-recipient is an explicit non-custody result. All exceptions mean no
successful acknowledgement, including commit acknowledgement or post-commit
cleanup failures where custody may already exist. Retry the original tuple and
exact bytes; reopen after a poisoned-handle failure. Errors do not include
recipient values, private MIME or delivery keys. An external adapter must map
these results to its own transport policy and must not emit success early.

=head1 DEPENDENCIES

Overnet::Mail::Envelope, Email::Address::XS, Digest::SHA, JSON and Moo::Role.

=head1 INCOMPATIBILITIES

Requires SQLite schema 6 or PostgreSQL mail schema 4. Older schemas are rejected
unchanged; no migration is supplied. The existing direct receipt API is retained
for trusted storage callers and is not an alternative untrusted ingress API.

=head1 BUGS AND LIMITATIONS

Single-recipient atomicity only. A multi-recipient adapter must retry each
recipient with a stable key and acknowledge only according to its reviewed
custody contract. No bounce, quarantine, delivery status notification, route
reassignment, mailbox deletion, quota, authentication or production service is
implemented. Local process-crash tests do not establish physical durability.

=head1 AUTHOR

Overnet Mail contributors.

=head1 LICENSE AND COPYRIGHT

GPL version 3; see the LICENSE file distributed with this software.

=cut
