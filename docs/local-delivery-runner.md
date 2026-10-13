# One-shot local delivery runner

**Fixture-only prototype, not an operational sender.** `DeliveryRunner` connects
the durable outbox to the existing `LoopbackSMTP` adapter. Each invocation claims
at most one due recipient, opens at most one loopback SMTP exchange, and attempts
one fenced completion. It creates no daemon, CLI, background loop, account,
authentication, TLS, Internet routing or real mail delivery. Tests bind only
127.0.0.1 on OS-assigned ephemeral ports.

## Acceptance and custody boundaries

A caller explicitly builds an immutable `RawMessage`, private `Envelope` and
finalized `Submission`, then calls `Store->enqueue_submission`. That existing
transaction atomically stores the message and all ordered recipient positions.
Archive-only acceptance stays archive-only. The runner never implicitly enqueues,
rewrites bytes, derives recipients from headers or creates a second queue.

```perl
my $receipt = $store->enqueue_submission(
  mailbox_id => 'fixture', idempotency_key => 'request-1', item => $submission,
);
my $runner = Overnet::Mail::DeliveryRunner->new(
  store => $store,
  transport => Overnet::Mail::Transport::LoopbackSMTP->new(port => $fixture_port),
  clock => sub { time },
  retry_after => 60,
  lease_seconds => 300,
  settlement_seconds => 5,
);
my $result = $runner->run_once(mailbox_id => 'fixture');
```

This is a trusted-caller API. Mailbox IDs do not authenticate callers. The Store,
LoopbackSMTP and clock are injected; subclasses allow controlled fault injection.
The supported adapter destination remains hardcoded IPv4 loopback. An arbitrary
subclass or clock callback is executable trusted code, not a sandbox. Constructor
options and run arguments are allowlisted. No credentials or alternative network
destination can be configured through this runner.

## Exactly one bounded attempt

1. Anchor monotonic time before reading the caller's trusted integer clock and
   claiming one due recipient. Store commits the lease before returning; no
   database transaction spans SMTP I/O
2. Copy the original mailbox, delivery ID and attempt before passing the claim
   to the transport. The claim contains only this recipient, never sibling or
   blind-recipient lists
3. Read time again and admit an attempt only if the remaining conservative lease
   budget fits the adapter's full `attempt_seconds` plus `settlement_seconds`.
   A bad/backwards clock, expired lease or insufficient budget prevents sending
4. Pass the lease-derived monotonic cutoff, less the settlement reserve, into
   the loopback adapter. Its own attempt deadline and the supplied cutoff both
   apply; validation and process scheduling consume those same deadlines
5. Read current wall and monotonic time before Store completion with the original
   fence. Preserve observed custody evidence if completion cannot be recorded

The adapter's four classifications keep their existing meanings. Confirmed means
complete final SMTP 250 and local MTA custody, not recipient mailbox delivery or
read status. Permanent means explicit rejection/local unsupported wire form.
Transient and uncertain retain their different acceptance evidence. Any uncaught
transport exception or invalid report is conservatively uncertain, even when the
exception may have occurred before sending: the runner cannot infer side effects
from an exception string. Addresses, bytes, peer text and exception messages are
never returned as diagnostics.

The caller supplies a fixed `retry_after` of 1–86400 seconds. It is used only for
transient/uncertain results. `lease_seconds` is 1–3600, default 300; `settlement_seconds` is 1–30, default 5. Existing Store
rules still cap attempts at five, fence stale results, delay eligible retries and
preserve uncertainty summaries. A call never sleeps, retries, drains the queue,
renews leases or sends a second recipient. Repeated calls are explicit caller
actions; terminal recipients are never retried. Duplicate envelope positions stay
separate requested deliveries.

## Durable result versus observed transport evidence

`run_once` returns `{ status => 'idle' }` if no recipient is due. Otherwise it
returns the original `delivery_id`, `attempt`, and `outcome`, plus:

- `status => 'recorded'` and `state`: Store acknowledged committed completion
- `status => 'unrecorded', error => 'lease_unavailable'`: no transport call was
  made because the second clock read failed, moved backwards or the remaining
  lease could not fit the full attempt plus settlement reserve;
  `outcome` is undefined
- `status => 'unrecorded', error => 'completion_failed'`: completion was not
  acknowledged, for example because of DB failure, bad time or a stale lease.
  `outcome` retains observed transport evidence, including confirmed custody

Unrecorded is **not** proof the DB transaction rolled back. A commit can succeed
and its acknowledgement be lost. Inspect Store status before deciding anything:
a committed terminal state remains terminal. Do not treat unrecorded confirmed
custody as an instruction to resend. The result deliberately does not claim a
durable state on that path. It contains no raw report or arbitrary transport
metadata. Before a claim exists, initial clock/configuration/claim failures throw
fixed value-free errors. A claim error can itself follow a committed lease with
a lost acknowledgement; no SMTP call occurs in that case.

## Crash, time and fencing limits

A process can receive SMTP 250, then exit or lose DB access before writing the
outcome. Local status is still leased until Store lazily recovers it on the next
claim. Lease expiry records `lease_expired` and uncertainty, then may issue the
next attempt; on the fifth expiry it exhausts. The database cannot reconstruct
remote custody from this gap. The tests explicitly demonstrate that recovery and
that another attempt can duplicate a message already accepted by the fixture.
There is no exactly-once delivery guarantee.

A completion timestamp at or beyond lease expiry is rejected. A newer worker's recorded result cannot
be overwritten by an older worker finishing late, even if the older worker also
observed 250. Fencing protects database writes only: it cannot recall bytes sent
to an MTA.

### Fixed lease budgeting

The runner reserves the adapter's configured total `attempt_seconds` (default 10)
and an explicit `settlement_seconds` (default 5). Construction rejects a lease
that does not exceed their sum plus the one-second rounding allowance, before any
claim can be consumed. With defaults the minimum viable lease is 17 seconds.
It never renews a lease or starts
a reduced-budget attempt merely to squeeze work into an almost-expired claim.
One additional whole second is deducted for the worst case of floor-rounded Unix
time. This rounding allowance is separate from the settlement reserve.

The initial monotonic anchor is taken before the first clock callback and claim.
The conservative lease deadline is that anchor plus `lease_until - initial_now - 1`.
A second anchor, taken before the pre-send clock callback, maps its wall-clock
reading the same way; the earlier deadline wins. The remaining-time check occurs
after that callback. Thus delayed claims, clock callbacks and validation cannot
restart or lengthen the allowance. A forward clock adjustment may shorten it.
A backward reading fails closed. At the exact remaining-budget admission boundary,
the configured attempt and reserve fit; any smaller budget refuses transport.

The adapter receives the conservative lease deadline minus the settlement reserve,
and caps it again by its own entry-time attempt deadline. Its existing
[supervisor](local-smtp-adapter.md#total-smtp-attempt-deadline) stops/reaps the SMTP
child, retaining queued body/custody evidence. Validation and scheduling elapsed
after admission are charged to the same cutoff; no connection starts if validation
exhausts it. Before settlement the runner also checks its conservative monotonic
lease deadline, so a frozen integer clock cannot authorize an already-overrun attempt.

The reserve is headroom, **not a database commit deadline**. Store checks the
completion timestamp supplied before its serialized transaction; lock waits,
queries or commit acknowledgement can outlast the reserve. An acknowledged commit
is still `recorded`. Failures and lost acknowledgements remain `unrecorded` with
the observed outcome intact. The original attempt fence rejects a delayed result
if another worker has reclaimed or settled the delivery. There is no DB cancellation,
automatic renewal, hard whole-method bound or recovery of lost remote evidence.

Clocks must return floor-rounded integer Unix seconds in Store's supported range
and remain trusted, consistent and nondecreasing across workers and calls. The
runner checks rollback within each invocation. A clock jump during SMTP or clock
skew between workers can still allow early reclamation relative to a previously
mapped monotonic deadline. OS scheduling pauses, process creation/cleanup,
uninterruptible waits and parent crashes also prevent hard real-time guarantees.
Clock synchronization and operational supervision remain prerequisites. These
bounds reduce stale-send opportunities; they do not provide exactly-once custody
or a guarantee that two attempts can never overlap.

## Verification and next boundary

Tests use real SQLite files and forked local SMTP fixtures, with deterministic
fault injection for claim/finish failures, process exits after observed SMTP 250,
lost commit acknowledgements, stale concurrent workers, independent recipient
outcomes and bounded exhaustion. Original message bytes and envelope-only blind
recipients remain covered. All normal, author, per-file coverage, mutation and
source-distribution gates apply. Process exits are not power-loss certification.

Existing mature MTAs must own downstream routing, retries and DSN processing;
accepted MTA custody must not be retried merely because recipient delivery is not
yet known. A production worker still needs operational supervision, scheduling,
authorization, authenticated verified TLS as
applicable, and actual MTA/client interoperability testing. This milestone neither
implements nor certifies those boundaries. See the [SMTP adapter contract](local-smtp-adapter.md)
and [outbox contract](transactional-outbox.md).
