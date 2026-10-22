# Trusted local recipient routing and custody

This connects an explicitly supplied envelope recipient to Store custody and the
read-only Dovecot lab. It is a trusted local library boundary, not an SMTP/LMTP
listener, account login or deployed mail service. No credentials, authentication
prototype, network exposure or persistent Dovecot copy is added.

## Provision and receive

```perl
$store->ensure_mailbox(mailbox_id => 'alice');
$store->register_recipient(recipient => 'alice@example.test', mailbox_id => 'alice');
my $result = $store->receive_delivery(
  source_id => 'local-mta', idempotency_key => 'stable-queue-id',
  recipient => 'alice@example.test', message => $raw_message, received_at => 100,
);
```

Registration requires an existing mailbox, is idempotent for the same binding,
and refuses reassignment. Multiple explicit addresses may name one mailbox.
Routes persist in SQL with no removal/update API. Reassignment requires a future
reviewed retry/revocation contract; direct SQL changes are outside this boundary.

The existing Email::Address::XS/Envelope contract validates printable ASCII bare
addresses up to 1024 input bytes. Only domain case folds; local-part case stays
significant, including quoted parts. No plus stripping, wildcard, catch-all,
forwarding or To/Cc/Bcc inference occurs. SMTPUTF8 and transport negotiation
remain future MTA work. Opaque message headers are not sanitized or rewritten.

Receive accepts exactly source_id, idempotency_key, recipient, RawMessage message,
and received_at. It rejects mailbox_id/namespace overrides and private envelopes.
Size, token and timestamp validation also applies to replays and unknown addresses.

## Custody and retry contract

- Unknown recipient returns only `{status => 'unknown_recipient'}`, with no bytes,
  mailbox, membership, UID, archive or outbox creation.
- Success returns only `{status => 'received', receipt => $receipt}`. The receipt
  contains entry_id, content_sha256 and received_at, not routing/private metadata.
- Exceptions are not successful acknowledgements, including uncertain commit or
  post-commit cleanup failures. Replay original identity/bytes and reopen poisoned
  handles when required. Never acknowledge before the method returns success.

Route lookup and receipt/Blossom acceptance share one serialized transaction.
Successful SQL commit is the custody boundary; no additional queue database or
Dovecot authority is introduced. An adapter must map results to its protocol and
retry policy. No SMTP response, bounce or sender-outbox settlement is generated.
Multiple recipients are individually atomic, not an all-recipient transaction.
If a later recipient fails, earlier custody remains and must replay safely.

Replay identity is `(source_id, canonical recipient, idempotency_key)`. The source
is a stable trusted ingestion namespace and the key a stable upstream queue
identity, neither derived from untrusted MIME headers. New source/key means new
delivery, even for the same bytes. This is not transport-wide exactly-once mail
if the upstream peer loses or changes its identity.

The namespace hashes an unambiguous JSON string tuple of source and canonical
recipient; SQL compares the delivery key separately. Direct receive_message uses
the disjoint `direct` namespace, preserving every previously valid direct key.
Aliases, sources or keys create separate receipts/UIDs sharing immutable bytes.
Exact replay returns the original time/UID; changed bytes conflict. Immutable
bindings prevent a retry from silently moving to another mailbox.

Existing mailbox listing/entry/UID APIs and Dovecot project only selected-mailbox
content. Registration, direct receipt APIs and SQL remain trusted administration,
not alternate untrusted ingress. A mailbox ID or registered address is not an
authentication credential. Future adapters must not expose arbitrary Store APIs.

## Explicit schema boundary

New SQLite stores use application ID 1330463049, schema 6; PostgreSQL mail schemas
use version 4. recipient_routes binds addresses by foreign key to existing
mailboxes. mailbox_entries.receipt_namespace separates uniqueness by mailbox,
namespace and idempotency key. Public direct receipt APIs/projections are unchanged.

SQLite 1 through 5 and PostgreSQL 1 through 3 are rejected unchanged. There is no
migration, route inference or promotion of existing archive data. In particular,
the previous read-only Dovecot milestone's SQLite 5/PG3 requires a future explicit
reviewed migration. Keep a verified backup and matching prior code; do not open
production stores with this development schema.

## Verification and limits

Tests cover canonical routing, unknown-recipient zero custody, immutable routes,
source/alias/direct namespaces, exact bytes, isolation, shared content, replay,
rollback, lost acknowledgement, corruption, concurrent retries and process-kill
recovery. PostgreSQL tests require an explicitly supplied disposable database;
mandatory CI fails rather than skips if absent. Existing per-file quality gates
remain 95% statements, 85% branches and 100% subroutines.

```sh
OVERNET_MUTATION_FILES=lib/Overnet/Mail/Store/Inbound.pm \
OVERNET_MUTATION_TEST_COMMAND='prove -Ilib t/inbound.t t/inbound-recovery.t' \
  bash scripts/check.sh mutation
```

The [Dovecot lab](../lab/readonly-imap/README.md) registers synthetic routes,
delivers through this API and fetches using standalone Dovecot 2.4.5 over pipes.
It checks destination isolation, replay, unknown addresses, independent clients
and offline/reconnected retrieval on SQLite and PostgreSQL. No protocol parser
is reimplemented. These tests do not certify power-loss durability, login, live
Internet mail reception, throughput or broad ordinary-client interoperability.
