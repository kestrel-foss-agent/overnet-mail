# Durable IMAP-facing identifiers

This storage-only milestone adds the persistent identifier contract required by
[RFC 9051 section 2.3.1.1](https://datatracker.ietf.org/doc/html/rfc9051#section-2.3.1.1).
It is not an IMAP server, authentication system, account directory or deployment.
The trusted caller continues to select an already-authorized opaque mailbox ID.
There is one incoming collection per mailbox, without folders, flags or expunge.
Existing receipt API shapes and global `entry_id` semantics are unchanged.

## API

```perl
my $empty = $store->ensure_mailbox(mailbox_id => 'recipient');
my $state = $store->mailbox_state(mailbox_id => 'recipient');
# {uidvalidity => 1, uidnext => 1, message_count => 0}

my $receipt = $store->receive_message(
  mailbox_id => 'recipient', idempotency_key => 'delivery-1',
  message => $raw_message, received_at => 100,
);
my $page = $store->mailbox_uid_entries(
  mailbox_id => 'recipient', after_uid => 0, limit => 100,
);
my $entry = $store->load_mailbox_uid(mailbox_id => 'recipient', uid => 1);
```

`ensure_mailbox` initializes persistent empty storage state and returns current
`uidvalidity`, `uidnext` and `message_count`. It does not create or identify an
account. `receive_message` initializes the same state when absent. Repeated or
concurrent initialization converges on one row. Outgoing archive/outbox creation
does not initialize an incoming mailbox.

`mailbox_state` is read-only and returns those three fields or nothing for an
absent mailbox. `message_count` counts membership rows, never infers count from a
counter. `mailbox_uid_entries` returns `uid`, `entry_id`, `content_sha256` and
`received_at`; `load_mailbox_uid` adds an exact `RawMessage` in `message` or
returns nothing if absent. Every query is mailbox-scoped with explicit fields.
No private envelope, delivery key or other-recipient metadata is exposed. Fetch
uses the existing Blossom integrity checks; metadata reads do not audit bodies.

Tokens retain the receipt API's bounded ASCII grammar. The UID cursor is a
canonical decimal integer 0..4294967295; fetch accepts 1..4294967295. Default
cursor is 0 and limit 100; explicit limits are 1..1000. Explicit invalid values
are rejected, not replaced with defaults. Pages are ordered by UID, strictly
after the cursor. Missing mailbox listings return an empty array without writes.

## Allocation and custody

Each mailbox has nonzero 32-bit `uidvalidity` and `uidnext`. A permanent singleton
allocator starts at 1 and supplies increasing UIDVALIDITY values for newly
initialized mailboxes. It is independent of clocks and current mailbox counts.
Each mailbox starts with UIDNEXT 1 and assigns strictly increasing local UIDs.
Global receipt IDs can have unrelated gaps and must never be used as IMAP UIDs.
The same blob in multiple mailboxes or under distinct keys gets independent
membership and UIDs, without duplicating byte authority.

UID allocation, mailbox initialization, both counter increments, membership and
Blossom custody share Store's existing serialized SQL transaction. SQLite uses
immediate transactions and PostgreSQL uses its database-wide advisory lock and
READ COMMITTED snapshot. PostgreSQL counters use BIGINT, not signed 32-bit INT.
No speculative UID or state is returned before commit. Rollback restores all
allocation state; gaps in PostgreSQL global entry sequences do not affect UIDs.
Exact same-key replay verifies bytes before returning the original receipt and
does not advance either counter. Lost acknowledgement resolves through replay.
The first `received_at`, bytes and UID remain immutable across restart.

UIDNEXT 4294967295 is reserved as the terminal state. The final allocated UID is
4294967294; new receipts then fail before storing content or changing state.
This conservative one-value reservation keeps every advertised UIDNEXT nonzero
and 32-bit. Reads, existing empty-state ensures and exact replay remain usable.
There is no automatic rollover, renumbering or UIDVALIDITY change. The last
UIDVALIDITY is 4294967295; the allocator stores internal sentinel 4294967296 and
then rejects only creation of new mailboxes. Existing mailboxes still work.

## Snapshot boundary

Every call observes a coherent per-call transaction. Separate calls are not a
single SELECT/session snapshot. For the current append-only immutable model an
adapter may capture state, enumerate pages, and retain only UIDs less than the
captured UIDNEXT. Stop as soon as that bound is reached or the listing ends.
That stable prefix must contain the captured message count. Later arrivals are
visible on the next synchronization. This permits bounded enumeration without
holding a transaction across a client connection. A future deletion, recreation
or mutable-flag model must introduce and review stronger snapshot semantics.

The IMAP server adapter must own session-relative sequence numbers and use the
persisted UIDs, not allocate a competing set. Any server index must be a disposable
projection; the SQL mailbox and Blossom bytes remain the only authority.

## Schema, restore and future mailbox lifecycle

New SQLite files use schema 5 (application ID 1330463049); new PostgreSQL mail
schemas use version 3. SQLite 1..4 and PostgreSQL 1..2 are rejected unchanged,
including prior receipt history. No implicit backfill or migration is supplied.
Existing stores require a separately reviewed, backed-up migration before this
code can be used with their data. Do not delete an old store to make it open.

No deletion/recreation API exists. Future deletion must retain the permanent
allocator; never reset it or derive it from surviving mailbox rows. Recreating a
mailbox name must not reuse a previously exposed UIDVALIDITY/UID pair. This
counter is local to the database's identity history, not globally unique between
independent fresh databases.

Restoring a backup that rolls back previously exposed UID history behind the
same server/mailbox identity is unsafe. Future restore tooling must preserve
all exposed history or assign UIDVALIDITY greater than every previously exposed
value. A rolled-back allocator cannot establish that upper bound by itself.
Replacing a database with a fresh schema is not a safe identity reset. There is
no production backup/restore or migration guarantee in this milestone.

## Verification

Tests cover empty and implicit initialization, per-mailbox ordering and privacy,
replay, snapshot prefixes, concurrent writers, rollback, hard interruption, lost
acknowledgement, restart, both exhaustion boundaries and unchanged old schemas.
The same state machine runs on SQLite and PostgreSQL, with real PostgreSQL CI
required alongside per-module coverage and targeted mutation review. A passing
storage test does not verify ordinary-client IMAP compatibility.
