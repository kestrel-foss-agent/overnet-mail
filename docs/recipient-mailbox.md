# Authoritative recipient mailbox receipts

This milestone adds a durable local incoming-mail collection to the existing
SQLite and PostgreSQL Store implementations. The database is the one authority
for recipient membership; Net::Blossom remains the shared immutable byte and
blob-metadata store on the same DBI connection. It does not start an SMTP, LMTP,
IMAP, native transport or authentication service. The separate real-MTA lab still
uses Dovecot as an external reference recipient, not as an Overnet backend.

## Boundary and API

An already-trusted caller selects the recipient's opaque `mailbox_id` and calls:

```perl
my $receipt = $store->receive_message(
  mailbox_id => 'recipient-account', idempotency_key => 'inbound-delivery-123',
  message => $raw_message, received_at => 100,
);
my $page = $store->mailbox_entries(
  mailbox_id => 'recipient-account', after_entry_id => 0, limit => 100,
);
my $entry = $store->load_mailbox_entry(
  mailbox_id => 'recipient-account', entry_id => $receipt->{entry_id},
);
```

`message` must be a RawMessage. Submission objects and private envelopes are not
accepted by this API. Tokens use the same bounded ASCII grammar as archive IDs.
`received_at` is required: caller-supplied canonical Unix seconds from 0 through
9999999999. It records the first receipt, not a parsed Date header or a claim
that a remote peer delivered at that exact time. Authorization, routing and local
account existence must be established by the trusted caller before entering this
boundary. Neither a known mailbox ID nor a content hash confers permission.
The library never derives recipients from To, Cc, Bcc or other MIME headers.

Each receipt contains exactly `entry_id`, `content_sha256`, and `received_at`.
The same mailbox/key and exact bytes replay the original receipt, retaining the
first timestamp even when the retry supplies a different valid timestamp. The
acceptance size limit and argument validation still apply before replay. Changed
bytes conflict without exposing either message in the diagnostic. Different
mailboxes or receipt keys create different entries sharing the same blob.

These receipt keys and IDs are separate from the existing archive/submission
namespace. `accept_item`, `enqueue_submission`, `load`, and the outgoing queue
retain their existing behavior. Archive or outbox creation never creates an
incoming membership, and receipt creation never enqueues an outgoing delivery.
Receiving multiple recipients is an explicit sequence of individually atomic
receipts; this API does not promise all-recipient atomicity or a network response.
An adapter must define its custody/retry policy before connecting this to a real
SMTP, LMTP or native transport peer.

## Recipient isolation and exact bytes

`mailbox_entries` returns only receipt metadata. It uses `mailbox_id` in SQL,
orders by increasing entry ID and includes only IDs strictly greater than the
cursor. The default limit is 100; explicit limits must be 1 through 1000. The
cursor is a canonical integer from 0 through 999999999999999999. Global entry IDs
can have gaps belonging to other mailboxes or rolled-back PostgreSQL sequences;
they are not message counts, contiguous sequence numbers, IMAP UIDs, public IDs
or credentials. Each call sees its own transaction snapshot, so later committed
entries are visible on subsequent pages. Timestamp order is irrelevant.

`load_mailbox_entry` takes the selected mailbox and positive entry ID and returns
receipt fields plus the exact RawMessage, or nothing if absent in that mailbox.
It never follows sender archive records. Both APIs explicitly project their
fields: no archive IDs, receipt keys, envelope sender, blind-recipient list or
other-recipient metadata is returned. Sharing bytes with an outgoing submission
does not share its private envelope. This is isolation within a trusted API, not
an authenticated security boundary for an untrusted client.

Raw inbound MIME is deliberately opaque and may itself contain Bcc text or other
untrusted headers. Receiving never strips, parses, reconstructs or rewrites those
bytes. Existing finalized outbound Submission restrictions remain in force.

Metadata listings do not read or audit message bodies. Fetch, replay and shared
content reuse verify the existing Blossom integrity contract, including hash,
length and exact byte comparison where original accepted bytes are available.
Missing or corrupt content fails closed; the library never silently repairs it.

## Custody, failure and offline retrieval

`mailbox_entries` directly references both Blossom blob metadata and byte rows.
No mailbox-body copy, second SQL content table or independently authoritative
Dovecot/Maildir copy is introduced. Incoming membership, any new blob bytes and
metadata all commit in Store's one existing serialized transaction.

A successful SQL commit is the durable custody boundary. Before commit, upload,
metadata, membership or commit failure produces no successful receipt and rolls
back new bytes and membership together. Previously committed shared content is
preserved. Ordinary component deletion cannot orphan receipt-only references.
A lost commit acknowledgement is resolved by retrying the original key and exact
bytes. Post-commit staging cleanup can fail after custody has committed; the
explicit Store diagnostic says so and asks for replay. Failed rollback poisons
the handle and requires reopening. No transient failure means successful receipt.

After successful commit, another connection can list and fetch the entry while
the original sender and receiving client are offline. Process-kill tests establish
application-crash recovery, not physical power-loss, host failure or production
backup certification. Existing database, filesystem, staging-file privacy and
hardware durability assumptions continue to apply. No deletion, garbage
collection, quota or retention policy is added.

## Schema and validation

New SQLite databases use application ID 1330463049 and schema version 4. New
PostgreSQL mail schemas use independent version 2. Prior versions are rejected
unchanged. There is no implicit migration, mailbox inference or promotion of old
archive records. Preserve a verified backup and use prior code for old stores
until an explicit reviewed migration exists. PostgreSQL still requires separate
upstream Blossom schema provisioning before the Store creates its mail tables.

Tests cover exact binary bytes, independent archive keys, cross-mailbox lookup,
interleaved pagination, timestamp disorder, receipt replay, corruption and shared
content retention. Recovery tests interrupt receipt processing and simulate lost
acknowledgements, and concurrent callers must converge on one receipt. Mandatory
CI uses real PostgreSQL in addition to SQLite, with unchanged per-module quality
thresholds and targeted mutation review. Passing local SQLite checks alone is
not PostgreSQL evidence.

## Ordinary-client milestone still ahead

This establishes a single incoming collection per selected mailbox. It does not
implement folders, flags, expunge, UIDVALIDITY, IMAP UID allocation, account
provisioning or ordinary-client retrieval. No compatibility-matrix row becomes
end-to-end verified merely from these tests.

The next integration must use a maintained IMAP server's supported backend
interfaces with this same authoritative membership and bytes, or explicitly
review a migration of authority. A separately authoritative SQL flag store and
Dovecot mailbox copy are prohibited. Authentication and receipt routing must be
reviewed before exposing any network interface. The prior authorization
prototype is not a dependency and is not activated by this milestone.
