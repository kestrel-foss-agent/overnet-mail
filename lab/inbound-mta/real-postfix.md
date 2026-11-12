# Disposable inbound Postfix integration follow-up

This is a **prepared, not yet executed** real-engine test increment for the
persistent-intake prototype. Local static and SQLite fixture checks are not
Postfix or PostgreSQL evidence. Do not call the inbound milestone complete until
the new CI job passes on the actual published commit and its logs are reviewed.
There is no deployment, real mail, authentication change or Internet relay.

## Why a separate lab

The existing [real-MTA lab](../../docs/real-mta-lab.md) already demonstrates the
isolation pattern needed by Postfix: a disposable Docker container with distinct
root, Postfix and mailbox service identities. Its assertions cover outbound
custody, not this inbound adapter. This follow-up uses that same pattern with a
separate image, separate queue and separate required CI job. It does not modify
the existing outbound proof or substitute its passing results for inbound tests.

The local editing environment cannot provide Postfix's required service users
or start the PostgreSQL socket. Installing another client cannot remove that
boundary. This work prepares CI execution without retrying those restricted
operations, changing local sandbox policy or using a replacement transport.

## Run

On an authorized Linux Docker runner with GNU timeout:

```sh
bash scripts/inbound-mta-lab.sh check
```

The image uses official Debian snapshot dependencies, the repository's published
CPAN dependency contract and hash-pinned pymilter. Dependency downloads occur at
build time with package service startup disabled. The test container has
`--network none`, no published ports, host mounts, Docker socket or privileged
mode. Interfaces, routes and listeners are checked in the container. SMTP binds
only its private loopback interface. PostgreSQL and Milter use Unix sockets.
Resource limits, build/test deadlines and cleanup are mandatory. Missing engines,
commands or assertions fail rather than skip. Root-required service operations
are guarded by image markers and refuse host execution.

Each Store engine receives a fresh ledger, queue and database. PostgreSQL runs
with fsync and full_page_writes enabled under its separate service identity,
uses local peer authentication and the dedicated synthetic `intake` database.
No actual account or password is used. The Store fixture creates its dedicated
schema using upstream supported Blossom setup. The delivery helper still only
exposes receive_delivery, not administrative setup.

## Assertions in the proposed CI gate

The same SMTP-to-Store suite runs with SQLite and PostgreSQL:

- smtplib submits fixed synthetic MIME to real Postfix. Installed libmilter
  invokes the production intake callbacks over its Unix protocol, and real
  Postfix pipe processes invoke the unchanged delivery adapter/Perl helper.
- Duplicate sender token headers are removed; folded headers, leading tabs,
  sender Received fields, dot transparency and base64 binary MIME retain exact
  bytes at the documented Milter callback boundary.
- Alice commits but the test wrapper returns EX_TEMPFAIL to Postfix instead of
  its successful acknowledgement. Bob is accepted by Postfix but initially lacks
  a Store route. Both remain queued. Restart and actual pipe retry preserve
  Alice's token, timestamp and UID. Adding Bob's route drains the existing queue
  without duplicating Alice.
- New byte-identical SMTP submissions and reinjection of a valid old token get
  independent tokens and new UIDs. Sender headers never recover trusted identity.
- Privileged `postsuper -r` is observed separately from ordinary restart. The
  queue ID changes and pickup prepends an extra Received header. The gate
  requires the strict adapter to defer with the old token still present, preserve
  Store state and retain Postfix custody. This unsupported path must not silently
  become a new delivery or cause broad stripping of sender Received headers.
- Missing ledger and altered pipe input defer without new Store custody. Restoring
  the original binding/bytes allows the same queue to drain.
- The PostgreSQL pass stops and restarts the real server while delivery is queued,
  checking temporary failure and persistence of earlier Store receipts.
- Unknown/external envelope recipients, declared oversized messages and missing
  Milter are rejected without successful SMTP custody or new Store entries.
- A trusted inspection fixture verifies immutable bytes, hashes, UID identity and
  timestamps through Store. Outbound/archive tables must remain empty.

The pipe wrapper is an explicit test seam. `before-*`, `after-*` and `alter-*`
files are root-controlled test instructions, never selected by a message. A
lost acknowledgement is simulated by returning 75 **after a real Store commit**;
it does not simulate a machine power failure, kill at an exact instruction or
lost final SMTP 250. The local wrapper regressions validate these test seams
against SQLite but cannot replace running the Postfix suite.

Queue observations respect `postqueue -j`'s non-atomic scans: duplicate exact
IDs are coalesced only if stable fields match, distinct IDs are never combined,
and absent IDs are polled within a bound. Queue emptiness alone is never enough
to pass delivery: exact expected Store receipt counts must also be observed.

## Restricted ingress and remaining limits

One explicit synthetic address map, one Milter and one recipient per pipe
invocation are allowed. The pipe uses CRLF framing and no flags that prepend
headers or alter bytes. Normal pickup/sendmail/postdrop submission is disabled.
The private pickup service exists solely for the bounded, root-controlled
administrative requeue assertion; no public pickup socket is created. No SMTP
Internet client transport, catch-all, alias expansion or automatic Bcc route
is enabled. This is not a production configuration template.

The existing standalone Dovecot readback workflow stays mandatory and unchanged.
This new job inspects authoritative Store bytes directly, so it does not yet
prove one continuous real-Postfix-to-Dovecot session. PostgreSQL Dovecot readback
through this new intake remains a separate extension even after this gate passes.
Neither test suite establishes power-loss durability, rollback-safe backups,
production retention/quota, SMTPUTF8, TLS, DNS, delivery notifications or general
mail-client compatibility. No exactly-once Internet delivery claim is made.

The original component suite, source distribution checks, author checks and
unchanged coverage floors remain in force. No existing verification is replaced
or weakened by this follow-up.
