package Overnet::Mail::Store::Mailbox;

use strictures 2;
use Moo::Role;

use Carp         qw(croak);
use Scalar::Util qw(blessed);

our $VERSION = '0.001';

requires qw(_dbh _transaction _item _store_content _content _insert_id);

sub _deploy_mailbox_tables {
  my ($self, $primary_key, $integer) = @_;
  my $dbh = $self->_dbh;
  $dbh->do(<<"ENTRIES");
CREATE TABLE mailbox_entries (
      entry_id $primary_key CHECK(entry_id BETWEEN 1 AND 999999999999999999),
      mailbox_id TEXT NOT NULL,
      idempotency_key TEXT NOT NULL,
      content_sha256 TEXT NOT NULL REFERENCES blossom_blobs(sha256)
        REFERENCES blossom_blob_data(storage_key),
      received_at $integer NOT NULL CHECK(received_at BETWEEN 0 AND 9999999999),
      UNIQUE(mailbox_id, idempotency_key)
)
ENTRIES
  $dbh->do('CREATE INDEX mailbox_entries_cursor ON mailbox_entries(mailbox_id, entry_id)');
  $dbh->do('CREATE INDEX mailbox_entries_content ON mailbox_entries(content_sha256)');
  return;
}

sub receive_message {
  my ($self, %args) = @_;
  _mailbox_token($args{mailbox_id});
  _mailbox_token($args{idempotency_key});
  _mailbox_integer($args{received_at}, 0, 9_999_999_999);
  if (!blessed($args{message}) || !$args{message}->isa('Overnet::Mail::RawMessage')) {
    croak 'receive_message requires a RawMessage';
  }
  my ($message) = $self->_item($args{message});
  return $self->_transaction(
    sub {
      my $dbh      = $self->_dbh;
      my $existing = $dbh->selectrow_hashref(
'SELECT entry_id, content_sha256, received_at FROM mailbox_entries WHERE mailbox_id = ? AND idempotency_key = ?',
        undef, $args{mailbox_id}, $args{idempotency_key},
      );
      if ($existing) {
        my $stored = $self->_content($existing->{content_sha256});
        if ($existing->{content_sha256} ne $message->content_sha256 || $stored->raw_bytes ne $message->raw_bytes) {
          croak 'mailbox idempotency key conflicts with received message';
        }
        return $existing;
      }
      $self->_store_content($message);
      $dbh->do(
        'INSERT INTO mailbox_entries (mailbox_id, idempotency_key, content_sha256, received_at) VALUES (?, ?, ?, ?)',
        undef, $args{mailbox_id}, $args{idempotency_key}, $message->content_sha256, $args{received_at},);
      return {
        entry_id       => $self->_insert_id('mailbox_entries', 'entry_id'),
        content_sha256 => $message->content_sha256,
        received_at    => $args{received_at},
      };
    }
  );
}

sub mailbox_entries {
  my ($self, %args) = @_;
  _mailbox_token($args{mailbox_id});
  my $after = exists $args{after_entry_id} ? $args{after_entry_id} : 0;
  my $limit = exists $args{limit}          ? $args{limit}          : 100;
  _mailbox_integer($after, 0, 999_999_999_999_999_999);
  _mailbox_integer($limit, 1, 1_000);
  return $self->_transaction(
    sub {
      return $self->_dbh->selectall_arrayref(
'SELECT entry_id, content_sha256, received_at FROM mailbox_entries WHERE mailbox_id = ? AND entry_id > ? ORDER BY entry_id LIMIT ?',
        {Slice => {}}, $args{mailbox_id}, $after, $limit,
      );
    }
  );
}

sub load_mailbox_entry {
  my ($self, %args) = @_;
  _mailbox_token($args{mailbox_id});
  _mailbox_integer($args{entry_id}, 1, 999_999_999_999_999_999);
  return $self->_transaction(
    sub {
      my $row = $self->_dbh->selectrow_hashref(
        'SELECT entry_id, content_sha256, received_at FROM mailbox_entries WHERE mailbox_id = ? AND entry_id = ?',
        undef, $args{mailbox_id}, $args{entry_id},);
      return if !$row;
      return {%{$row}, message => $self->_content($row->{content_sha256})};
    }
  );
}

sub _mailbox_token {
  my ($value) = @_;
  if (!defined $value || ref $value || $value !~ /\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z/smx) {
    croak 'mailbox_id and idempotency_key must be bounded ASCII tokens';
  }
  return;
}

sub _mailbox_integer {
  my ($value, $min, $max) = @_;
  if (!defined $value
    || ref $value
    || $value !~ /\A(?:0|[1-9][0-9]{0,17})\z/smx
    || $value < $min
    || $value > $max) {
    croak 'mailbox argument must be a bounded canonical integer';
  }
  return;
}

1;

__END__

=head1 NAME

Overnet::Mail::Store::Mailbox - authoritative local recipient mailbox receipts

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  my $receipt = $store->receive_message(
    mailbox_id => 'recipient-account', idempotency_key => 'delivery-123',
    message => $raw_message, received_at => 100,
  );
  my $entries = $store->mailbox_entries(mailbox_id => 'recipient-account');
  my $entry = $store->load_mailbox_entry(
    mailbox_id => 'recipient-account', entry_id => $receipt->{entry_id},
  );

=head1 DESCRIPTION

Composed into Store for both SQLite and PostgreSQL. Recipient membership and
immutable Blossom bytes commit together. Membership is independent of sender
archives and private envelopes. This is a trusted local storage boundary, not
a network service, authentication mechanism or IMAP implementation.

=head1 SUBROUTINES/METHODS

=head2 receive_message

Requires C<mailbox_id>, C<idempotency_key>, a C<message> RawMessage and
C<received_at> Unix seconds (canonical integer 0 through 9999999999). IDs use the
Store's bounded ASCII token grammar. Submission is deliberately not accepted.
The store independently enforces its message-size limit. The trusted caller must
authorize and resolve the recipient mailbox; message headers never select it.

Returns C<entry_id>, C<content_sha256> and C<received_at>. Replaying the exact
bytes under the same mailbox/key returns the original receipt and timestamp,
even if the supplied valid timestamp changed. Conflicting bytes fail. These keys
are independent of archive/submission keys. Different keys create distinct
entries while shared content stays immutable. SQL commit is the custody boundary;
pre-commit failures roll back membership and any new content together. Lost
acknowledgements resolve by exact replay. Post-commit staging-cleanup errors can
mean custody committed; follow Store's explicit diagnostic and replay guidance.

=head2 mailbox_entries

Requires C<mailbox_id>. Optional C<after_entry_id> defaults to 0 and must be a
canonical integer from 0 through 999999999999999999. C<limit> defaults to 100 and
must be 1 through 1000. Returns an array of receipt hashes, ordered by increasing
entry ID strictly after the cursor. An absent mailbox returns an empty array.
The cursor is database-local, not an IMAP UID or an authorization credential.

Lists membership metadata only; it does not read or rehash message bodies.
Listing is a per-call snapshot. Later committed receipts appear on later pages;
timestamps do not determine ordering. There is no deletion or renumbering API.

=head2 load_mailbox_entry

Requires C<mailbox_id> and a positive canonical C<entry_id> of at most 18 digits.
Returns nothing when absent in that mailbox, otherwise receipt fields and a
RawMessage in C<message>. Fetch and replay verify content length, hash and exact
bytes through the existing shared storage path. All result shapes omit archive
IDs, idempotency keys, sender and private envelope/other-recipient metadata.
Opaque inbound MIME can itself contain Bcc text: this API never rewrites it.

=head1 DIAGNOSTICS

Invalid inputs, replay conflicts and storage failures throw value-free errors.
No operation grants permission merely because a caller knows a mailbox, ID or
hash. Lower-level transaction failure and reopen rules are inherited from Store.

=head1 CONFIGURATION AND ENVIRONMENT

Uses Store's one DBI handle and existing serialized, durable transactions.
No environment, network, authentication, route or mailbox provisioning is added.

=head1 DEPENDENCIES

Moo::Role, strictures, Carp and Scalar::Util; shared Store supplies persistence.

=head1 INCOMPATIBILITIES

Requires SQLite mail schema 4 or PostgreSQL mail schema 2. Prior schemas are
rejected unchanged; no implicit migration or adoption of archive rows occurs.

=head1 BUGS AND LIMITATIONS

This is a single incoming mailbox collection per caller-selected mailbox ID.
Folders, flags, expunge, UIDVALIDITY, IMAP UIDs, account authorization, quotas,
network receive adapters and backup/restore tooling remain unimplemented.
A future ordinary-client adapter must use this same authority or an explicit
reviewed migration. A second independently authoritative mailbox is prohibited.

=head1 AUTHOR

Overnet Mail contributors.

=head1 LICENSE AND COPYRIGHT

GPL version 3; see the LICENSE file distributed with this software.

=cut
