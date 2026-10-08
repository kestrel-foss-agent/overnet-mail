# Isolated real-MTA custody and reference mailbox lab

This is one bounded interoperability proof point toward mandatory ordinary-email
compatibility. It is **not a deployed service or an Overnet mailbox backend**.
No authentication prototype, account grant, DNS, live mail, external relay, or
public listener is enabled. Production readiness is not implied.

## Custody and authority

1. `enqueue_submission` archives original immutable octets in Net::Blossom and
   creates the application outbox atomically in the existing SQLite Store.
   Blossom remains authoritative for the originating archive; the Store owns
   originating outbox state.
2. `DeliveryRunner` uses the existing `LoopbackSMTP`/Net::SMTP adapter. Postfix's
   final DATA `250` transfers transport custody. The application's `delivered`
   state means **confirmed MTA handoff**, not recipient delivery. It must not
   resend that confirmed handoff while Postfix is retrying downstream.
3. Postfix durably queues mail when Dovecot LMTP is stopped, retaining queue
   identifiers across a Postfix restart. After recovery it delivers to a synthetic
   external reference recipient using LMTP.
4. Dovecot alone owns that recipient's mailbox membership, flags, UID and
   UIDVALIDITY. Mail::IMAPClient reads and changes the reference mailbox using
   ordinary IMAP. Its Maildir is never registered with Blossom or treated as an
   alternate Overnet authority.

The application archive remains byte-identical. The received copy can contain
MTA/LMTP trace headers (for example Received, Return-Path and Delivered-To);
received message byte identity with the archive is not claimed. MIME body and
attachment bytes, dot transparency, visible headers and private Bcc envelopes
are checked separately. No Bcc field is inserted into finalized outbound bytes.

## Run and stop

On a Linux machine with Docker and GNU timeout:

```sh
bash scripts/real-mta-lab.sh check
```

The wrapper builds a disposable image, runs the required integration assertions,
then removes its own named container and image on success or failure. It does not
mount the checkout, host mail directories or Docker socket into the container.
The Docker build has network access solely for official Debian/CPAN dependencies;
package service startup is disabled during build. The test container uses
`--network none`, no published ports, no privileged mode and bounded CPU, memory
and process counts. Only its private loopback interface is allowed. The runtime
checks the interface, routes and actual listening addresses before the tests.

The in-container `/lab/control` commands provide bounded `postfix-start`,
`postfix-stop`, `postfix-flush`, `dovecot-start`, `dovecot-stop`, `queue-json`,
`check` and `stop`. Do not run those scripts as host service management tools;
they refuse to operate without the disposable image markers. Tests restart the
services without replacing their spool or mailbox directories. This demonstrates
service/process restart persistence, **not disk-loss or power-failure durability**.

Service startup redirects daemon standard streams to a private container log,
printed during cleanup, so restarts cannot keep the TAP harness pipe open.
Startup polls have a five-second bound; service commands have ten-second bounds.
The suite has a 180-second timeout and the outer container has a 240-second
bound with forced cleanup. Image build is bounded to 20 minutes. CI's required
`Real Postfix and Dovecot custody lab` job has a 25-minute limit; missing Docker,
engines, modules, listeners or assertions fails the job rather than skipping.
A failed engine job blocks the milestone even if the ordinary suite passes.

## Versions and reproducibility

- Perl official image: `perl:5.40.1-bookworm` (Debian 12 / Perl 5.40.1)
- Debian package indexes: immutable snapshot `20260901T000000Z`, including the
  Debian security archive; verified packages Postfix `3.7.11-0+deb12u1` and
  Dovecot `1:2.3.19.1+dfsg1-2.1+deb12u6`
- CPAN IMAP client: `Mail::IMAPClient` 3.43
- Application dependencies: repository `cpanfile` and existing minimum versions

The job prints the built image ID, installed Postfix/Dovecot package versions,
Perl version and IMAP client version. Preserve those logs with the commit when
comparing results. The base tag and general CPAN dependency graph are not a
cryptographic lockfile: rebuilds are not promised to be bit-reproducible. The
snapshot and explicit client version make the engine setup reproducible; image
IDs identify the exact tested build. No third-party preconfigured mail image is
trusted with this test.

## Rejection and isolation

SMTP/IMAP/LMTP bind only `127.0.0.1` on 2525/1143/2424 inside the isolated
namespace. Postfix has exactly two allowed addresses, `alice@reference.invalid`
and `blind@reference.invalid`. Unknown local users and external destinations
are rejected at RCPT, even from loopback: there is no `permit_mynetworks` bypass.
There is no SMTP Internet delivery transport in master.cf; default and relay
transports are explicit errors, and DNS lookup is disabled. LMTP uses a literal
loopback destination. Both recipient and IMAP authentication maps contain only
synthetic fixtures. Plaintext IMAP and the public `lab-only` fixture password
are appropriate solely inside this non-networked lab, never deployment defaults.

The test checks mixed accepted/rejected RCPT transactions without partial
application submission, and the configured 65536-byte SMTP size limit. Existing
per-recipient outbox semantics remain unchanged. This is not a general relay
configuration or production rejection/backscatter policy.

## Remaining limits

Existing ambiguous-acknowledgement and crash-recovery tests remain mandatory.
A crash after SMTP acceptance but before recording still permits duplicate
mail on retry. No exactly-once delivery claim is made. `DeliveryRunner` still
has no whole-attempt deadline or lease renewal; test-level timeout containment
does not repair that production limitation. Real TLS, authenticated submission,
Internet routing, DKIM/DMARC/SPF, DSNs, production supervision, broad SMTPUTF8
and ordinary mail-client compatibility require separate work and evidence.

The cloud editing environment has no Docker runtime, and its earlier local
service socket restriction is respected. It performs static/ordinary checks
only; real-engine execution belongs to the isolated CI job, not a workaround
transport or changed sandbox policy.

## Upstream references

- [Postfix relay and access control](https://www.postfix.org/SMTPD_ACCESS_README.html)
- [Postfix configuration parameters](https://www.postfix.org/postconf.5.html)
- [Dovecot 2.3 LMTP](https://doc.dovecot.org/2.3/configuration_manual/protocols/lmtp_server/)
- [Dovecot and Postfix LMTP](https://doc.dovecot.org/2.3/configuration_manual/howto/postfix_dovecot_lmtp/)
