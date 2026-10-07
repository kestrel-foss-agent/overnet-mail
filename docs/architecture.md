# Initial application contracts

This is the design boundary for subsequent implementations, not a claim that
these services are present in this foundation commit.

- Ordinary Internet mail is mandatory from the outset. SMTP submission,
  inbound/outbound SMTP and ordinary-client IMAP belong at mature MTA/mailbox
  boundaries. Do not build an ad-hoc Perl SMTP or IMAP server.
- Reuse CPAN modules for MIME, address parsing, authentication integration,
  database transactions and protocol clients. Candidate libraries must be
  selected, licensed and tested in the implementation that first uses them.
- One authoritative durable mailbox owns mailbox state. If Dovecot owns it,
  Overnet integrates through supported interfaces; a second independently
  authoritative SQL message/flag store is prohibited. If a database owns it,
  protocol access must be an explicit adapter to that same authority.
- Raw accepted MIME bytes are immutable. Parsed indexes and attachment metadata
  are derived and rebuildable. Changes requiring different wire bytes create a
  new version/blob with explicit provenance; never silently reserialize originals.
- Submission envelopes are separate from visible RFC 5322 headers. Bcc recipients
  remain envelope-only on recipient-facing deliveries. Composed delivery MIME is
  finalized before immutable storage; do not blindly forward a Bcc header from an
  untrusted submission. Logs and errors must not leak blind-recipient lists.
- Persist mailbox/outbox acceptance transactionally. Delivery state is recorded
  per recipient, with bounded retries and explicit permanent failure. An SMTP
  disconnect after remote acceptance can be ambiguous; do not promise exactly-once
  Internet delivery. Use idempotency keys within the application's own boundary.
- Authentication and authorization are distinct. No open relay, implicit trust
  of forwarded identity headers, secret logging, or cross-account blob access.
- Overnet transport cannot turn a chat direct message into email by changing
  labels. Routing, sender identity, MIME, durable offline behavior, mailbox state,
  bounces and recipient privacy need explicit contracts and integration tests.

## Initial threat model

Trust boundaries include ordinary clients, Internet peers, the authenticated
submission API, native transport, mailbox owner, blob storage and delivery workers.
Treat every message and attachment as untrusted. Cover oversized/deeply nested
MIME, header/address injection, malformed encodings, unsafe HTML, remote content,
path traversal, authorization bypass, queue exhaustion and replay.

The next implementation must define limits before accepting mail, refuse an
unauthorized relay attempt, bind identities to accounts, and retain enough audit
metadata for delivery diagnosis without storing secrets or blind-recipient lists
in user-visible logs. Backups, restore verification and blob/orphan reconciliation
must be designed with the authoritative store, before production readiness.

## Incremental delivery

0. This foundation: reused tooling, enforceable quality gates and reviewable contracts.
1. Durable mailbox/outbox/blob/authentication implementation with crash tests.
2. Native-to-native, native-to-Internet, Internet-to-native, and ordinary-client
   Internet paths with attachments, Bcc and offline delivery.
3. Complete IMAP/POP/JMAP/Sieve, migration and client-feature scope as approved.
4. Production abuse controls, fuzz/load tests, backups and recovery validation.
