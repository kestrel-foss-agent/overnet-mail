# Persistent intake and local Store delivery prototype

**Local synthetic prototype. No running mail service, deployment, authentication,
Internet SMTP listener, real mail, or complete Postfix integration proof.**
The Python/libmilter intake and one-recipient delivery command now implement the
identity boundary. They use the existing Perl Store, without introducing another
mailbox authority. Full Postfix master/pipe still requires a suitably isolated
multi-user runtime and end-to-end tests. Standalone Dovecot 2.4.5 readback from
this new SQLite delivery path has passed through local pipes without a multi-user
runtime. PostgreSQL remains unverified.

## Components and trust

- `intake.py init LEDGER` explicitly provisions a new, private SQLite intake
  ledger. It refuses to replace an existing file. Normal service/delivery never
  creates a missing ledger.
- `intake.py serve LEDGER SOCKET ROUTE...` uses pymilter/libmilter on a local Unix
  socket. The supported synthetic routes are fixed ASCII addresses. Unknown
  recipients are rejected before custody. The Milter must be the sole intake
  path and sole modifying filter; it strips every sender-supplied token header.
- At EOM it records a fresh 256-bit OS-random token, exact callback-boundary
  bytes, immutable recipient set and original timestamp in one serialized SQLite
  transaction with FULL synchronous commits. The token primary key detects
  collisions; bounded retries generate another token. It adds a token header
  only after commit. No queue ID, Message-ID, content hash or receipt timestamp
  participates in token allocation.
- `intake.py deliver LEDGER CONFIG RECIPIENT` reads one bounded CRLF queue stream
  from stdin with an absolute deadline. It requires one valid token, its existing
  ledger binding, the same bytes and an authorized envelope recipient. It calls
  `store-delivery.pl`, which exposes only `receive_delivery`, then succeeds only
  after the helper exits successfully and supplies the exact success marker.
  Every other outcome exits 75, including unknown Store recipients. It never
  constructs bounces or treats exception strings as permanent delivery errors.
- The trusted JSON config selects `{"engine":"sqlite","path":"/absolute/mail.db"}`
  or `{"engine":"postgres","dsn":"...","schema":"..."}`. Routes/mailboxes must
  already exist; no account provisioning command is exposed to message input.

The ledger retains immutable intake evidence, not user mailbox membership. Store
remains authoritative for receipts, UIDs, timestamps and retrieved bytes. The
ledger deliberately has no deletion/pruning API; production retention, quotas,
backpressure and lifecycle management are unresolved.

This is a trusted local interface, not a defense against a local process that
can write its ledger/config/queue or invoke the helper directly. Keep code,
configuration, sockets and directories restricted to the intended service users.
The separate Postfix `mail_owner` and pipe execution user must satisfy Postfix's
normal privilege checks. Do not alias them or disable checks to run this lab.

## Precisely defined byte boundary

Postfix does not expose original SMTP-wire bytes through Milter callbacks. It
hides its own prepended Received field, uses LF in folded header values, strips
whitespace before header colons, and normally strips a leading value space.

The intake requires protocol 6's HDR_LEADSPC capability and header add/change
actions. It retains header field case and leading value whitespace, converts
callback folding LF to CRLF, appends the header separator, and retains body
callback bytes unchanged. This bounded callback representation is the message
stored in both the ledger and Store. It is **not a claim of original-wire or
complete Postfix queue-file preservation**.

Delivery removes exactly the first, Postfix-generated Received field and the one
intake token field, then requires byte-for-byte equality with the immutable
ledger message. Sender Received fields, Bcc and all other MIME bytes remain data
and cannot choose recipients. No whole-message parsing/reserialization occurs at
delivery. Legal but non-reconstructible inputs, including pre-colon whitespace,
empty original header sets, and changes by subsequent filters, defer rather than
silently accepting altered bytes. The input is capped at 64 KiB of message plus
16 KiB of local transport headers; headers are also capped at 512 and recipients
at 32. Enforce Postfix's message/header limits before libmilter too.

## Required Postfix topology, not a tested deployment recipe

A real-engine harness must configure protocol 6, fail-closed Milter behavior,
explicit synthetic recipient maps, one recipient per pipe invocation,
`eol=\r\n`, and no pipe flags that insert or rewrite content (`B D F O R . >`).
Disable aliases, automatic BCC, canonical/masquerade rewrites, subsequent filters,
non-SMTP pickup/sendmail/postdrop ingress, and all Internet delivery transports.
A newly injected message must always traverse token-stripping intake. Merely
setting `non_smtpd_milters` does not prove that all privileged injection paths are
covered. Do not enable this prototype outside the bounded lab.

Ordinary queued retries, restart and partial-recipient delivery preserve the
persisted token. A new byte-identical intake receives a different token. A crash
before queue acceptance may leave an unused ledger row; it cannot acknowledge
Store custody. A lost Store acknowledgement is retried with the same token and
retains the original Store receipt. A lost SMTP final 250 followed by a **new
sender submission** can create another token and delivery; this is not exactly-once
Internet delivery.

Current Postfix `postsuper -r` documentation says administrative requeue bypasses
both Milter settings. Treat it as the same intake only while the original token,
recipient and bytes survive unchanged; otherwise defer for operator review.
Reinjection through the designated SMTP intake is a new delivery. Never recover
metadata from sender headers or guess a lost ledger binding from a queue ID.

Source initialization uses a random epoch plus independent random tokens, not a
rollback-prone counter. Restoring a ledger without a token causes deferral, not
recreation. Restoring Store or a queue/ledger snapshot independently can roll back
custody and is **unsupported**. Random IDs do not repair database rollback. Keep
ledger and Store crash/backup procedures coordinated; process tests do not prove
power-loss durability. Source replacement needs explicit operator planning.

## Local verification

Requires the normal Perl dependencies, Python 3.12+, pymilter 1.0.5, a C compiler,
and official libmilter development libraries. Installation into a workspace prefix
is supported; no root filesystem or OS-service changes are necessary for these
unit/component tests. Set PYTHONPATH/LD_LIBRARY_PATH for a local install.

```
python3 lab/inbound-mta/test-intake.py
prove -Ilib t/inbound-mta-contract.t t/inbound.t t/inbound-recovery.t
```

After building the existing pinned Dovecot lab and plugin, run:

```
python3 lab/inbound-mta/test-readback.py \
  --prefix /path/to/dovecot-245/runtime --plugin-dir /path/to/imap-plugin
```

That check follows intake delivery into real SQLite Store, then retrieves exact
MIME bytes through standalone Dovecot IMAP pipes. It verifies partial-recipient
retry, changed queue ID, unchanged replay UIDs, a new byte-identical intake,
independent recipient mailboxes and readback after reconnect.

The component checks exercise durable SQLite intake and real Store calls, plus
callback behavior through the installed library. They are not proof of Postfix queue,
master or pipe exit mapping. A multi-user isolated VM or container is required
for the full Postfix checks; installation of a Docker client alone
cannot provide the missing privilege boundary.

Official references:
- https://www.postfix.org/MILTER_README.html
- https://www.postfix.org/pipe.8.html
- https://www.postfix.org/postsuper.1.html
- https://pypi.org/project/pymilter/1.0.5/
