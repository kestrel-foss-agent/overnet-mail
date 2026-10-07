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

1. Read the caller's trusted clock and claim one due recipient. Store commits the
   lease before returning; no database transaction spans SMTP I/O
2. Copy the original mailbox, delivery ID and attempt before passing the claim
   to the transport. The claim contains only this recipient, never sibling or
   blind-recipient lists
3. Read time again. A bad/backwards clock or known-expired lease prevents sending
4. Call the loopback adapter once, then read current time and pass its outcome to
   Store completion with the original fence

The adapter's four classifications keep their existing meanings. Confirmed means
complete final SMTP 250 and local MTA custody, not recipient mailbox delivery or
read status. Permanent means explicit rejection/local unsupported wire form.
Transient and uncertain retain their different acceptance evidence. Any uncaught
transport exception or invalid report is conservatively uncertain, even when the
exception may have occurred before sending: the runner cannot infer side effects
from an exception string. Addresses, bytes, peer text and exception messages are
never returned as diagnostics.

The caller supplies a fixed `retry_after` of 1–86400 seconds. It is used only for
transient/uncertain results. `lease_seconds` is 1–3600, default 300. Existing Store
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
  made because the second clock read failed, moved backwards or showed expiry;
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

At exact lease expiry, completion fails. A newer worker's recorded result cannot
be overwritten by an older worker finishing late, even if the older worker also
observed 250. Fencing protects database writes only: it cannot recall bytes sent
to an MTA. The pre-send time check narrows an obvious stale-send window but does
not close the race or stop an in-flight slow-drip peer. Net::SMTP's timeout is
per I/O, not a total attempt deadline. There is no supervisor or whole-call time
bound. This is an explicit production blocker, not a reason to lengthen a lease
and claim the problem solved.

Clocks must return integer Unix seconds in Store's supported range and remain
trusted, consistent and nondecreasing across workers and calls. This runner checks
monotonicity within each invocation; Store also validates computed deadlines.
Clock synchronization/rollback handling remain operational prerequisites.

## Verification and next boundary

Tests use real SQLite files and forked local SMTP fixtures, with deterministic
fault injection for claim/finish failures, process exits after observed SMTP 250,
lost commit acknowledgements, stale concurrent workers, independent recipient
outcomes and bounded exhaustion. Original message bytes and envelope-only blind
recipients remain covered. All normal, author, per-file coverage, mutation and
source-distribution gates apply. Process exits are not power-loss certification.

Existing mature MTAs must own downstream routing, retries and DSN processing;
accepted MTA custody must not be retried merely because recipient delivery is not
yet known. A production worker needs a separately reviewed total-attempt execution
bound, supervision, scheduling, authorization, authenticated verified TLS as
applicable, and actual MTA/client interoperability testing. This milestone neither
implements nor certifies those boundaries. See the [SMTP adapter contract](local-smtp-adapter.md)
and [outbox contract](transactional-outbox.md).
