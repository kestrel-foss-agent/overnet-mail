# Transactional per-recipient outbox

This is a local, trusted-caller queue built on the shared Net::Blossom SQLite store.
It implements no network sender, SMTP/IMAP service, authentication, relay policy,
retry daemon, DSN/bounce generation or delivery guarantees beyond its local
transactions. No test sends mail or contacts a live service. The ordinary-client
compatibility matrix remains unverified.

## Explicit acceptance and separate identities

`accept_item` remains archive-only, for both opaque inbound `RawMessage` and
finalized `Submission` objects. Only `enqueue_submission` requests an outbox, and
it requires a finalized `Submission`; it cannot infer routing from visible headers.

One SQLite transaction accepts exact bytes and the private envelope, creates a
submission, and creates one delivery for each ordered envelope position. It
returns only after commit. A failure at any insert or commit leaves no partial
acceptance or queue. Explicitly enqueueing an identical previously archived item
with the same mailbox/key promotes that archive; failure leaves the original
archive intact. Archiving a queued item does not change its queue.

Identities are separate database-local namespaces, never interchangeable:

- `message_id`: accepted logical mailbox item
- `submission_id`: the explicit outbound request
- `delivery_id`: one envelope recipient position in that request
- `(delivery_id, attempt)`: one local lease generation, used to fence completion
- `content_sha256`: exact byte identity for sharing BLOB storage only
- RFC Message-ID: opaque content, with no uniqueness or deduplication role

Numeric values may coincide across namespaces. They are not globally unique or
secret authorization capabilities. `(mailbox_id, idempotency_key)` remains the
local acceptance key. Replaying equal bytes, sender and ordered recipients
returns the same submission/delivery IDs without changing any outcomes, attempts
or deadlines. Different keys yield different logical requests, even for equal
bytes and Message-ID. A conflicting key fails.

Duplicate addresses are deliberately distinct delivery positions. For example,
an envelope with the same address twice requests two deliveries; it is not
silently deduplicated. A caller that wants deduplication must do it explicitly
before finalizing the envelope and choosing its idempotency key.

## Bounded local state machine

New rows start `ready`, with attempt zero. `claim_delivery` selects one due row
within the specified mailbox, increments `attempt` and stores a lease deadline.
It commits before returning a claim. Concurrent processes use separate Store
connections and SQLite immediate transactions, so the same live attempt cannot
be issued to two claimers. No transaction or writer lock spans network I/O.

A transport adapter can report one of four explicit classifications:

- `confirmed` becomes `delivered`: requires conclusive acceptance evidence from
  the selected transport boundary; it does not mean the recipient read the mail
- `permanent` becomes `failed`: an explicit terminal failure
- `transient` becomes `deferred`, with an explicit delay of 1–86400 seconds
- `uncertain` remains visibly `uncertain`, with the same bounded delay: remote
  acceptance may have happened but its acknowledgement was lost

Every claim consumes one of five fixed attempts. A retryable result on attempt
five becomes `exhausted`; conclusive results on that attempt remain delivered or
failed. Expired leases record `lease_expired` and increment `uncertain_attempts`.
They become immediately eligible for retry, or exhausted on the fifth expiry.
Expiration is applied lazily by the next claim in that mailbox; a status read
alone does not mutate expired rows. This conservative classification also covers
a worker crash before it actually sent anything.

`last_outcome` and the cumulative `uncertain_attempts` remain visible across
retries, reconnects and later confirmation. Exhaustion is never rewritten as
proof of non-delivery. These summaries are not a full attempt/audit history.
There is no automatic reset or manual requeue API. Terminal delivery/failed/
exhausted rows cannot be claimed or finished again; replay does not resurrect them.

## Leases, clocks and ambiguous acknowledgements

Every queue operation takes caller-supplied integer Unix seconds. Callers must
use a trusted, consistent, nondecreasing clock in the documented range; time is
explicit to make recovery and boundary tests deterministic. Lease duration is
1–3600 seconds, default 300. Retry delay is supplied by the future transport
adapter; there is no backoff, jitter, domain throttling or lease-extension policy.
A wall-clock rollback can delay recovery; a forward jump can expire an active
worker. Clock synchronization and a suitable lease duration are operational
prerequisites before real delivery.

`finish_delivery` requires the current attempt number and a still-live lease.
At the exact expiry second it rejects completion, even before reclamation. A
stale success or failure cannot overwrite a newer attempt. Fencing only protects
local database updates: it cannot stop an expired worker's already-started
remote send. Retrying uncertain outcomes can deliver duplicates. There is no
exactly-once Internet-delivery claim.

If acceptance acknowledgement is lost, replay the original key. If a claim
acknowledgement is lost, its committed lease remains until expiration. If a
completion acknowledgement is lost, inspect status: a committed terminal outcome
remains terminal, while an uncommitted update restores the prior lease. This
library cannot reconcile evidence from a remote system that it never contacted.

Claims return exact immutable bytes, sender and only the selected recipient,
not sibling or blind-recipient lists. Status contains IDs and outcome metadata,
without addresses. These are private trusted-caller APIs; mailbox scoping does
not authenticate or authorize callers. Error messages omit supplied values and
SQL/trigger diagnostics. Protect the database, journals and backups as private
mail data under the existing local storage contract.

## Versioning and verification

New databases use schema version 3. Version 1 and 2 databases are rejected without
changing their schema, messages, BLOB bytes, envelope or markers. There is no
implicit migration or retroactive enqueue. Keep using the preceding code for
existing version-1 or version-2 data until an explicit backed-up migration is implemented;
do not relabel the version marker or create a replacement database over old data.
The same marker-only recognition limitation documented for local storage remains.

Tests cover insert/commit exceptions, process interruption during all acceptance
stages, partial recipient outcomes, duplicates and stable replay, six-process
concurrent enqueue/claim, expired/stale lease fencing, attempt exhaustion,
reconnect persistence, damaged queue replay, lost commit acknowledgements and
version-1 and version-2 data preservation. All existing style, coverage and source-distribution
gates apply. Process exits are not simulated hardware or power-loss certification.

The implementation reuses Net::Blossom’s SQLite byte and metadata stores on the
same DBI handle, alongside the existing DBD::SQLite, Moo and value objects. No
custom mail protocol or live infrastructure is introduced.
See [local storage](local-storage.md) for SQLite durability assumptions and
[the original contracts](architecture.md) for production work still required.

The subsequent [loopback SMTP prototype](local-smtp-adapter.md) exercises these
classifications on local fixtures only. It performs no automatic queue writes or
retries and is not an operational delivery service.
