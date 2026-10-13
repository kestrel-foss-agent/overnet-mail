# Read-only Overnet INBOX integration lab

This is a bounded **local synthetic storage integration**, not an IMAP service,
login implementation, account authorization design, or deployment. Dovecot CE
**2.4.5** supplies the mature IMAP and MIME parser. Overnet Store and its Blossom
backend remain the only authoritative mailbox and byte store. No IMAP listener,
Dovecot master/login process, passdb/userdb, credentials, real account mapping,
Maildir, mbox, or persistent Dovecot index is introduced.

The standalone Dovecot IMAP executable is connected to the test client by pipes.
Its PREAUTH greeting means the local test harness started it; it proves nothing
about login or user identity. Do not expose this process through a network proxy,
inetd, SSH login, or any other transport. The trusted test config selects one
synthetic mailbox and is not an authorization boundary.

## Reproduce

Install the repository's Perl 5.40+ dependencies first, plus C build tools,
pkg-config, OpenSSL headers, Python 3, curl and GNU tar. Use new build directories:

```sh
lab/readonly-imap/bootstrap-dovecot.sh /tmp/overnet-dovecot-245
lab/readonly-imap/build-plugin.sh /tmp/overnet-dovecot-245/runtime /tmp/overnet-imap-plugin
python3 lab/readonly-imap/test-bridge.py
python3 lab/readonly-imap/test-protocol.py \
  --prefix /tmp/overnet-dovecot-245/runtime --plugin-dir /tmp/overnet-imap-plugin
python3 lab/readonly-imap/test-readonly.py \
  --prefix /tmp/overnet-dovecot-245/runtime --plugin-dir /tmp/overnet-imap-plugin \
  --engine sqlite
```

For PostgreSQL, supply an existing **disposable local test database** whose role
can create/drop synthetic schemas and large objects. No password/credential setup
is supported by this lab. The test creates uniquely named `overnet_imap_*`
schemas, corrupts designated synthetic content, and removes its own schemas and
large objects. Never point it at a real mail database.

```sh
OVERNET_TEST_PG_DSN='dbi:Pg:dbname=overnet_mail_imap_test;host=127.0.0.1;port=5432' \
OVERNET_TEST_PG_USER=postgres \
python3 lab/readonly-imap/test-readonly.py \
  --prefix /tmp/overnet-dovecot-245/runtime --plugin-dir /tmp/overnet-imap-plugin \
  --engine postgres
```

CI runs both real engines; missing PostgreSQL configuration fails, never skips.
The ordinary Perl tests and coverage gates are separate from this C/IMAP lab.
Local testing may be unable to start PostgreSQL in restricted executors; that is
not evidence of a PostgreSQL pass. Require the new integration CI job on the
exact branch, PR, and merged main commits.

The harness generates a temporary wrapper with the same absolute Perl interpreter
that installed its dependencies. It execs the helper by an argument list. The
plugin executes that wrapper by an absolute filename, with a config filename as
one argument; no shell or command-string interpolation is involved. Python uses
standard-library `imaplib` with direct `Popen(argv, shell=False)` stream setup.

## Storage and snapshot contract

`store-helper.pl` calls only these existing Store read APIs:

- `mailbox_state(mailbox_id => ...)`
- `mailbox_uid_entries(mailbox_id => ..., after_uid => ..., limit => 128)`
- `load_mailbox_uid(mailbox_id => ..., uid => ...)`

The helper's SQLite connection uses `SQLITE_OPEN_READONLY`, `query_only` and
deferred read transactions. Missing files cannot be created. Empty/old/invalid
schemas fail without initialization or migration. PostgreSQL sets
`default_transaction_read_only` before constructing Store; the normal Store
schema validation and integrity code is reused. The lab's PostgreSQL fixture role
can write to prepare tests, so the session read-only setting is a safety guard,
not a claim of production least-privilege credential design.

The helper captures UIDVALIDITY, UIDNEXT and message count before enumeration.
It retains only the immutable prefix below captured UIDNEXT, validates strictly
increasing UIDs and exact count, and probes the next row to detect a count mismatch.
New receipts arriving between pages are excluded from that snapshot. The driver
imports authoritative UIDs into Dovecot's disposable in-memory index. NOOP/normal
synchronization can append newer UIDs; existing prefix, UIDVALIDITY and monotonic
UIDNEXT must agree. Reconnection rebuilds the projection. A deletion, reset,
restored/rolled-back database, or mutable-flag feature requires a new design.

IMAP exposes only INBOX. Other mailbox names are rejected and never interpreted
as database selectors or paths. Neither IPC request includes a mailbox/account
selector. No private delivery envelope, recipients, sender, or delivery key is
serialized into the helper protocol. Visible message headers, including any
original opaque Bcc header, remain part of the stored message bytes.

## Framing, limits, and failure behavior

One short-lived child handles one request and exits. Its only commands are
`SNAPSHOT\n` and `FETCH <uid>\n`. Snapshot responses are canonical decimal lines:
`OK <uidvalidity> <uidnext> <count>\n`, then `<uid> <received_at>\n` per entry.
Fetch responds `DATA <length>\n` followed by exactly that many binary octets.
Errors are generic `ERR\n` and nonzero exit; exception details are not exposed.
The C caller accepts data only after complete EOF and successful child exit.

Limits are deliberately fixed for this development milestone:

- 4,096 selected messages; an over-limit mailbox fails, never truncates/hides mail
- 10 MiB per original message; over-limit retrieval fails without replacement
- 32-byte requests, 16 KiB trusted JSON config, bounded responses and decimal fields
- 10-second absolute monotonic IPC deadline, including child exit
- Helper: 256 MiB address space, 8 CPU seconds, 9-second Perl alarm, no core files
- Dovecot test process: 512 MiB address space, 20 CPU seconds, no core files
- Dovecot command lines: 64 KiB; its pinned MIME parser defaults also limit nesting
  to 100 and total MIME parts to 10,000

Helper pipes are nonblocking, partial reads are assembled, output overflow is
rejected, and unrelated inherited descriptors are closed. Child stderr is
suppressed to prevent accidental exception/DSN/content disclosure. The direct
child is reaped; failure cleanup kills its private process group, including a
misbehaving test descendant retaining a pipe. No shell is used. This is a bounded
Linux/glibc test harness, not a hardened sandbox for untrusted executable helpers.
Trusted local helper/config paths and repository code must remain protected.

No message is substituted on missing/corrupt Blossom content, malformed IPC,
timeout or child failure. Dovecot may send BYE and end a failed BODY fetch. A
synchronization error can be an untagged NO followed by tagged NOOP OK, following
Dovecot's synchronization behavior; the previous index is unchanged. Tests check
these protocol distinctions rather than treating every tagged OK as fresh data.

The bridge uses bounded whole-message buffers and synchronous short-lived Perl
children. This is intentionally not a throughput, streaming-large-mail,
latency, denial-of-service, or broad ordinary-client compatibility milestone.

## Read-only behavior and exact bytes

SELECT/EXAMINE returns READ-ONLY and PERMANENTFLAGS (). The IMAP command hook
rejects explicit mutations, including STORE (even temporary flags), EXPUNGE,
APPEND/COPY/MOVE/REPLACE, folder changes and subscriptions. Inherited raw-storage
save callbacks are also explicitly rejected to avoid the raw helper's unsafe
missing-handler paths. No durable or temporary write feature is advertised as
supported. Dovecot's generic capability list is not a promise that every command
is permitted by this backend. CLOSE/UNSELECT/LOGOUT are safe session operations.

Blossom originals and Store integrity checks remain the exact-byte boundary.
Tested CRLF, NUL-free plain, base64 attachment, and multipart/quoted-printable
messages round-trip byte-for-byte through BODY.PEEK[], including partial reads.
Ordinary IMAP BODY fetch changes deliberately nonconforming NUL to 0x80 and lone
LF to CRLF. These are Dovecot read-time projections; the stored original and
helper fetch remain unchanged. BINARY applies content-transfer decoding and is
not an arbitrary-original-byte escape hatch. Never silently normalize stored
mail or claim every opaque original is wire-identical.

## Version coupling and sources

The plugin uses Dovecot development/private C vtables and raw/index parsing
helpers. It is compiled only against **2.4.5**, and the runtime checks the exact
Dovecot ABI. Rebuild and rerun all tests before upgrading. It includes IMAP
command hooks and is loaded only in the standalone IMAP executable, not doveadm.
The upstream source is downloaded at build time, not vendored:

- [Dovecot CE 2.4.5 release](https://dovecot.org/releases/2.4/dovecot-2.4.5.tar.gz)
- SHA-256 `868c2686a61b5f8e00a3e4721789b1ab46e6528fd773a5fbed07a6ecba7731e6`
- [Storage-driver design](https://doc.dovecot.org/2.4.3/developers/design/mail_storage.html)
- [Plugin ABI checks](https://doc.dovecot.org/2.4.3/developers/design/plugins.html)

The checksum is a reproducibility pin, not independent signature validation.
Relevant source paths are `src/lib-storage/index/raw/`, `src/lib-storage/index/`,
`src/imap/imap-sync.c`, `src/imap/cmd-store.c`, `src/lib-imap-storage/imap-msgpart.c`
and `src/lib-mail/message-parser.h`. No upstream source or binary is redistributed
in this directory. Integration code is GPL-3.0-only with the repository.
