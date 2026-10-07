# Local SMTP adapter and worker boundary

**Fixture-only prototype, not an operational mail sender.** This milestone tests
one ordinary SMTP handoff on literal IPv4 loopback. It creates no daemon, service,
authentication layer, open relay, DNS/MX routing, account, credentials, deployment,
provider integration or Internet delivery. No test contacts an external mail
service. Ordinary Internet email remains mandatory; the broader compatibility
matrix is still unverified.

## Reuse and trust boundary

`Overnet::Mail::Transport::LoopbackSMTP` delegates SMTP commands, sockets, EHLO /
HELO fallback, capability parsing, dot-stuffing and DATA framing to CPAN
[Net::SMTP 3.15 / libnet](https://metacpan.org/pod/Net::SMTP).
`SMTPClient` is an internal observer subclass, not a protocol implementation.
It delegates the documented [Net::Cmd response hooks](https://metacpan.org/pod/Net::Cmd)
and distinguishes complete, consistent peer replies from local synthetic errors.
The adapter is not a strict SMTP grammar validator beyond those observations.

The adapter accepts only `port` (1024–65535) and a per-I/O `timeout` (1–30 seconds,
default 2). Fixtures bind 127.0.0.1 on port zero and pass the OS-assigned port.
The destination is hardcoded to 127.0.0.1; no hostnames, alternative addresses,
Net::Config default hosts, recipient-domain resolution or DNS rebinding path.
Unknown options are rejected, including credentials, TLS, host and debug options.
Library debugging is explicitly disabled. Neither peer reply text nor addresses,
body data, library exceptions or blind-recipient lists are returned in diagnostics.

This is a trusted-caller test boundary. It does not authorize queue access or
verify sender ownership. Any local process can impersonate a fixture. Cleartext
loopback is not a production security policy. Direct use of the internal inherited
SMTPClient constructor is outside this API, just as direct Net::SMTP use is.

Before real use, a separate reviewed adapter needs an explicit MTA destination,
authorization, secure credential handling where required, fail-closed TLS
certificate-chain and hostname verification, downgrade protection and negative
TLS tests before any credentials or message bytes. TLS is **not implemented** in
this prototype; tests cannot establish authenticated or encrypted transport.

## Immutable bytes and ordinary message compatibility

`deliver($claim)` takes one RawMessage, one envelope sender and one recipient from
an existing outbox claim. It rechecks the existing finalized Submission privacy
boundary. Visible To/Cc/From do not choose envelope recipients or sender; the null
reverse-path remains `MAIL FROM:<>`. Exact address mode preserves quoted local
parts rather than allowing the client's heuristic address extraction. Bcc remains
envelope-only. Duplicate queue positions remain distinct attempts.

The DATA-compatible subset requires:

- At most 10485760 message octets
- Consistent CRLF throughout and an existing final CRLF
- No NUL, bare CR or bare LF; each line at most 998 octets before CRLF
- ASCII root headers, including encoded-word Unicode subjects; SMTPUTF8 is not
  implemented even when a peer advertises it
- ASCII envelope paths at most 254 octets before enclosing angle brackets
- Eight-bit bodies only with advertised 8BITMIME; binary MIME is unsupported
- Advertised SIZE checked before MAIL; empty/zero SIZE means no advertised limit

Finalized storage can hold more general bytes than this transport can carry.
Unsupported forms fail without rewriting or reserializing the immutable original.
A future composer may explicitly create a new transport-compatible version with
provenance. Base64 MIME attachments, quoted-printable, folded headers and dot-led
body lines need no mutation. The library adds and the test peer removes only SMTP
transparency framing; decoded received bytes must match the original exactly.

## One call, one recipient, one classification

The adapter does not own a Store connection, lease, queue transaction, retry loop
or backoff. Each call opens one connection and sends at most one RCPT and one DATA.
The result contains only `outcome`, a fixed `stage`, and `smtp_code` (undefined if
there is no complete peer evidence). Queue identity and attempt remain the caller's
claim values, never taken from a server response.

- `confirmed`: a complete final 250 after DATA. The local MTA accepted custody;
  this is not proof of delivery to a recipient mailbox or that mail was read
- `permanent`: a complete peer 5xx rejection, or an explicitly unsupported local
  wire form/capability/size. These local limitations need composition/configuration
  work before a newly authorized submission, not silent mutation and resend
- `transient`: a complete peer 4xx rejection, a pre-body connection/protocol error,
  or malformed SIZE capability. No acceptance evidence was seen
- `uncertain`: sending the body started but final acceptance/rejection evidence
  is missing, truncated, inconsistent, unexpected, timed out or interrupted

Only exact expected success codes advance stages (220 greeting, 250 hello/MAIL,
250/251/252 RCPT, 354 DATA, 250 final). Net::Cmd normally uses synthetic 421 for
local errors; the observer uses zero so a real complete peer 421 remains distinct.
A stale 550 from an unfinished multiline reply cannot become permanent failure.
The library handles replies, but these gates do not claim full RFC grammar checks.

Cleanup closes the socket directly. It never sends QUIT/RSET on a failed DATA
stream, since the library can implicitly finish pending data before a command.
Once final 250 is observed, a disconnected cleanup does not erase acceptance.
There is no automatic retry, including after a lost final acknowledgement.

## Explicit worker mapping, no operational worker

A future trusted worker claims one recipient and commits that lease before I/O,
then calls the transport and passes only its `outcome` to `finish_delivery`, with
the original mailbox, delivery ID, attempt and current trusted time. Transient
and uncertain results require an explicit bounded `retry_after` (1–86400 seconds).
The queue's existing attempt cap, lease expiry and fencing still apply. Tests
exercise this mapping against an isolated SQLite database, with delivered, failed
and uncertain siblings and unchanged persisted message bytes.

A per-I/O timeout is not a whole-attempt deadline: a slow-drip peer can prolong an
exchange. This prototype has no lease renewal or execution supervisor. Production
work must bound total I/O time against a lease and retain ambiguity when a worker
or acknowledgement is lost. Local fencing cannot stop an already-started remote
send, and retrying uncertain delivery can duplicate mail.

Existing mature MTAs must own Internet routing, downstream SMTP retry/backoff,
queueing and DSN/bounce processing. The application outbox tracks the handoff to
that boundary; accepted MTA custody must not be retried merely because downstream
delivery has not yet occurred. Reconcile any future worker's scheduling with this
ownership model rather than implementing a second competing Internet MTA.

## Verification scope

Forked scripted peers listen only on OS-selected 127.0.0.1 ports. These are test
fixtures, not a deployable server. They cover null and quoted envelopes, one RCPT,
raw MIME and eight-bit round-trips, library dot-stuffing, HELO-only peers, capability
and size limits, peer 4xx/5xx responses, disconnects, incomplete/inconsistent replies,
unexpected success codes, final-ack timeouts, body errors and partial queue results.
Full style, author, per-file coverage, mutation and source-distribution gates apply.

These fixtures do not certify real MTA/client interoperability, TLS, SMTPUTF8,
BINARYMIME, email authenticity, abuse controls or Internet delivery. The next
production milestone must explicitly provide and test those boundaries.
