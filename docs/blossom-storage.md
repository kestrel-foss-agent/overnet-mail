# Shared Net::Blossom storage foundation

This adapter uses Net::Blossom's published SQLite components as its byte and
metadata storage foundation. It does not create or run a Blossom HTTP server,
expose public content addresses, or send mail. This is still a private,
trusted-caller development prototype. Authentication is a separate workstream.

## One database and transaction

`Net::Blossom::Server::Backend::SQLite::BlobStore` owns `blossom_blob_data`.
`MetadataStore` owns `blossom_blobs` and `blossom_owners`. Mail adds its message,
private envelope, scoped idempotency, submission and recipient-outbox tables to
the same database. The previous `contents` table is gone. No second content
store or mailbox authority is maintained.

Both public components are constructed with the mail store's single DBI handle
while AutoCommit is enabled. Mail uses MetadataStore's `with_transaction` to
coordinate acceptance, reads and queue updates. Its outer guard additionally
handles begin/commit exceptions and failed rollback, invalidating an unusable
connection. The top-level Blossom upload coordinator is deliberately not nested
inside a mail transaction: it owns a different transaction scope.

For new content, mail locks the blob, writes a staged BlobStore upload, prepares
it inside the database transaction, and inserts Blossom metadata. It verifies
the newly prepared database bytes, then inserts all mail records and optional
outbox deliveries. Only the SQL commit gives custody; writer `commit` afterward
removes staging. Any pre-commit failure rolls back both Blossom tables and all
mail changes and calls writer `abort` to remove staging.

A commit error never produces a successful receipt. If an acknowledgement is
lost after an actual commit, replay the original mailbox/key and exact item.
A post-commit staging-cleanup error explicitly reports that acceptance committed
and gives that replay guidance. Cleanup failure after a failed rollback never
hides the need to reopen the poisoned connection.

## Integrity, privacy and custody

The adapter retains SHA-256, exact byte comparison, byte-length and SQLite BLOB
type checks on every read, reuse, replay and newly prepared upload. It does not
parse or reserialize MIME. Metadata uses `application/octet-stream`; the field
is an internal storage label, not an inferred MIME Content-Type. `uploaded` is
the local blob-insertion Unix time, not an email Date or delivery timestamp.

Mail references are separate from Blossom pubkey ownership. The owners table
is unused. Mail rows reference both blob metadata and byte rows with foreign
keys. Deleting either half while mail still references it fails, including via
ordinary component methods. This relies on enabled foreign keys; a database
administrator can still bypass or corrupt constraints. Mail does not provide
blob deletion or garbage collection. Orphan bytes or missing metadata fail
closed rather than being silently adopted, overwritten or repaired.

Private envelopes, including blind recipients, remain mail-only records. Blob
metadata has no email addresses. Hash sharing does not merge logical messages
or acceptance keys. Queue claims retain selected-recipient-only projections,
fenced leases, explicit uncertainty and crash recovery. No private mail is
published to a remote Blossom service.

The upstream SQLite writer creates random system-temporary files with mode
0600. Normal success and exception paths remove them. A close/unlink failure or
abrupt process termination can leave a staging file; it is not accepted or authoritative mail and is never
used for recovery. Replaying an acceptance resolves database state but does not
remove a prior leftover staging file. Protect the system temporary directory and any disk/swap or
backup containing it as private mail storage. Automated staging cleanup,
at-rest encryption and full production retention/backup operations remain
unimplemented. Do not broadly delete temporary files while uploads are active.

## Schema and supported backends

New mail databases use application ID 1330463049 and schema version 3. Old
version-1 and version-2 mail databases are rejected unchanged. Existing foreign
or standalone Blossom databases are also rejected; this is component reuse,
not an implicit adoption/migration of another application's data. Keep a verified
backup and continue using the prior code until a reviewed migration exists.
Marker recognition is not a full schema or integrity audit.

SQLite is the only supported mail adapter in this change. It preserves DELETE
journaling, synchronous=EXTRA, enabled foreign keys, immediate transactions,
a bounded busy timeout and one connection per process. Filesystem/S3 byte stores
cannot provide the same all-SQL atomic boundary and are not interchangeable here.

Net::Blossom's PostgreSQL components are a suitable next candidate, but adding
them requires PostgreSQL-specific mail schema/identity handling, transactional
queue concurrency, durability configuration and tests against a real server.
Their large-object readers use a cloned connection and stream, so they cannot
verify a newly prepared uncommitted object through the same read path as SQLite;
stream closure and in-transaction verification need an explicit design. This
change neither enables PostgreSQL nor claims tested backend parity.

## Verification scope

The mail suite exercises shared handles, no duplicate byte table, read and
prepare integrity, protected custody, staged-file permissions/cleanup,
commit/rollback/cleanup failures, scoped replay and private envelopes. Existing
outbox and runner tests continue against Blossom storage, including process
interruptions after byte and metadata insertion, later mail inserts and commit,
concurrent enqueue/claim, stale leases and uncertain completion. Hard process
exits are not physical power-loss certification.

The dependency is the CPAN release Net::Blossom::Server::Backend::SQLite 0.001004
or newer; the initially tested release matches upstream commit
084c7db09465f3470fec9748b4e467bea5f567f9. See the third-party notice for provenance.
The existing per-module coverage, author/style and source-distribution gates
remain mandatory. No quality template or threshold is relaxed for this reuse.
