# Required compatibility acceptance matrix

All scenarios below are **not implemented** in the foundation. No test currently
claims email interoperability. Add executable integration tests with the actual
MTA/mailbox adapters before marking any row verified.

| Path | Required checks |
| --- | --- |
| Ordinary client to Internet | Authenticated submission, TLS policy, SMTP envelope, MIME preservation, delivery status |
| Internet to ordinary client | Inbound SMTP acceptance, authoritative persistence, ordinary IMAP retrieval |
| Native to Internet | Sender/address mapping, mature MTA handoff, attachments and per-recipient outcomes |
| Internet to native | Address resolution, durable offline delivery, raw MIME and threading metadata |
| Native to native | Same email semantics, authenticated identity, durability and replay/idempotency behavior |
| All sending paths | To/Cc/Bcc separation, no Bcc leakage, recipient isolation, partial and transient failure |
| All storage paths | Exact raw bytes, transactional accept/outbox, quotas, crash/retry recovery, restore |
| All client paths | Multipart/alternative, Unicode, binary attachment, encoded filename, large-message limit |

Use local test peers and deterministic fixtures. Do not send real email from CI.
Success is observable end-to-end delivery and retrieval, not merely queue insertion.
