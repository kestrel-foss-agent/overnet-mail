# Inbound MTA adapter acceptance contract

## Status and smallest missing increment

This document and `t/fixtures/inbound-mta/partial-retry.json` define a **local
synthetic acceptance contract**. A [persistent intake and local delivery
prototype](../lab/inbound-mta/README.md) now implements the component boundary;
it has not passed a complete Postfix master/pipe integration. The executable
oracle `t/inbound-mta-contract.t` drives the existing SQLite `receive_delivery`
API. It opens no socket, launches no mail service and sends no email.

The [existing real-MTA lab](real-mta-lab.md) proves application-outbox handoff
to Postfix and delivery into a separate reference Dovecot mailbox. The
[read-only IMAP lab](../lab/readonly-imap/README.md) retrieves the authoritative
Store through Dovecot after direct Store calls. Neither currently demonstrates
an MTA delivering into that Store. The next integration should connect these
boundaries, not create a second mailbox authority or implement SMTP/IMAP parsing.
It can use published main without the separate, unpublished Blossom reuse work.

## Trusted delivery request

A future local adapter accepts one recipient at a time from a configured MTA.
It must call `receive_delivery` with exactly these fields:

- `source_id`: a configured trusted ingestion namespace, stable across restart.
- `idempotency_key`: a trusted, durable delivery identity stable across attempts.
- `recipient`: the MTA's envelope recipient, never a MIME header address.
- `message`: the exact complete octets presented at the chosen ingestion boundary,
  wrapped in `Overnet::Mail::RawMessage` without reserialization.
- `received_at`: bounded integer time supplied by the trusted adapter; replay
  returns the original accepted time rather than replacing it.

Store path, credentials, mailbox identity and administration are not selectable
from the message. Routes must already exist. Registration is not authentication.
Do not expose arbitrary Store methods or provision accounts while delivering.
Validate the configured message-size limit and metadata before custody; a future
stream reader must bound input before allocating the entire payload.

**Queue-ID-only integration is prohibited:** a raw MTA queue ID is not proven
permanently unique or stable across all queue operations. Before wiring an MTA,
document how its trusted interface supplies a persistent non-reused delivery
identity, including restart, requeue, expiry and source-instance replacement.
Do not infer one from Message-ID, Received, content hashes or untrusted headers.
Do not invent an MTA argument/macro to supply it. A changed identity can create
another delivery and therefore cannot support an exactly-once claim.

A source namespace does not prevent reuse within that source. With identical
bytes, a reused source/key/recipient tuple silently returns an old receipt,
including its old UID and timestamp. With different bytes it raises a conflict.
Neither outcome is correct for a genuinely new delivery. A content digest,
Message-ID, receipt time, per-attempt random ID or token map indexed only by
queue ID does not fix both suppression and retry duplication.

The accepted design requires an independent trusted intake token, allocated and
persisted before the first attempt, bound durably to the particular delivery and
exact bytes. Retries and lost acknowledgements reuse that token. A genuinely
new delivery gets a different token even when its queue ID and bytes match an
older delivery. Token creation and binding must be crash-safe and serialized;
source replacement or restoration must not roll back the token namespace.
Administrative requeue/reinjection must either preserve that binding through a
trusted path or explicitly be treated as a new delivery. Never recover a token
from sender-controlled headers. A missing or unprovable binding must defer
without calling Store or acknowledging custody.

The local prototype now persists independent tokens through a libmilter intake
and verifies their immutable bindings before Store delivery. Its documented
byte boundary and restricted ingress topology are essential, and full real-engine
verification remains outstanding. Do not wire `${queue_id}` directly to
`idempotency_key` or deploy a queue-ID-only pipe.
The synthetic fixture supplies tokens directly so it can test the required
Store behavior without pretending to prove their production provenance.

## Custody and acknowledgement

| Store observation | Required adapter behavior |
| --- | --- |
| `received` returned normally | Report successful local custody only after return. Retain the receipt's original identity/time on replay. |
| `unknown_recipient` | Do not acknowledge custody. Use the selected MTA's explicit unknown-recipient handling; no bytes or membership may be created. |
| Any exception, interruption, timeout, malformed result or lost acknowledgement | Do not report success. Preserve the original identity/octet stream for retry; reopen the Store as required. Do not interpret exception strings as permanent protocol errors. |
| Same identity with changed octets | No success, no overwrite. Preserve the original receipt and raise a bounded operational conflict for investigation. Do not retry altered content indefinitely without an operator policy. |

This table is not an SMTP response-code, LMTP multi-status or process-exit-code
implementation. Mapping it to a mature MTA's supported delivery interface is a
separate integration step, with real-engine tests. Unknown-recipient rejection
before an Internet MTA accepts responsibility is preferable; a post-queue failure
must follow that MTA's reviewed delivery-status/backscatter policy, not send an
ad-hoc bounce from the application.

For multiple recipients, each successful call commits independently. Failure for
Bob does not roll back Alice. A retry of the original request must replay Alice
and then accept Bob without consuming another Alice UID. A return to the local
caller is not proof that its acknowledgement reached the MTA. This does not
promise exactly-once Internet delivery, sender-outbox settlement, power-loss
survival, or complete ordinary-client compatibility.

Never copy raw exception text, MIME headers, Bcc values, whole envelopes or
credentials into protocol responses. Use bounded categorical diagnostics and
restricted operator correlation metadata. Preserve incoming raw headers as data:
the synthetic Bcc header below is deliberately untrusted and does not add a
recipient. This fixture is not a claim that the adapter sanitizes inbound MIME.

## Executable synthetic transcript

Run from repository root, after installing the normal project dependencies:

```sh
prove -Ilib t/inbound-mta-contract.t
```

`message.eml` has CRLF line endings, a MIME text part, binary attachment content,
a fixed Message-ID and header addresses different from the registered envelope
recipients. `partial-retry.json` describes these consecutive attempts:

1. Alice commits, but the test discards the acknowledgement.
2. Bob fails before the Store call.
3. An unknown recipient is refused without custody.
4. Retrying Alice with domain case changed replays the original receipt.
5. Retrying Bob creates his first receipt.
6. Repeating Bob preserves his receipt and UID.
7. Reusing Alice's identity with changed octets cannot overwrite custody.
8. A new trusted intake token with the same queue ID, Message-ID and complete
   bytes creates a distinct entry, rather than replaying the earlier receipt.
9. A header-only address has no implicit route.
10. A changed queue ID with the original trusted token replays the original
    receipt. This assumes trusted token preservation, not a Postfix guarantee.

After every attempt the test reopens the real SQLite Store and checks mailbox
counts, UIDNEXT, complete octets and unchanged first receipts. Sender archives,
private envelopes and outboxes remain empty; both recipients share one blob.
The fixture carries `queue_id` only as observational metadata; the oracle passes
only `delivery_token` to Store as its idempotency key. The token is not generated
by Postfix. `drop_ack` and `fail_before_store` are **test harness faults**, not simulations of
Postfix behavior. Reopening a database is not a process-kill or power-loss test.
Existing `inbound-recovery.t`, PostgreSQL and Dovecot tests remain mandatory;
this fixture does not replace them or lower coverage gates.

## Gate for the subsequent real-engine increment

The [prepared disposable inbound lab](../lab/inbound-mta/real-postfix.md) supplies
a proposed CI harness for this gate. It has not yet executed against the real
engines and is not evidence that the gate passes.

Choose and document a supported mature-MTA local interface and its delivery
identity first. Then run the same scenario through that actual interface, in an
isolated synthetic lab, and verify normal, lost-ack and partial-recipient retries.
Retrieve from the same Store with the existing Dovecot integration. Test input
bounds, EOF/truncation, deadlines, unknown recipients, metadata spoofing and
failure-to-acknowledge paths. Validate both SQLite and PostgreSQL. Keep this
fixture as the oracle, not evidence that any of those integrations already pass.
No authentication prototype, new external listener, real mail, deployment or
changes to restricted/unreviewed reuse code are part of this increment.
