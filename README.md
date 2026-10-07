# Overnet Mail

A Perl email application built around ordinary Internet email compatibility.

**Status: development, no running mail service.** The CI foundation is followed
by immutable message/envelope objects, shared Net::Blossom SQLite storage and an explicit
transactional per-recipient outbox. A loopback-only SMTP adapter exercises local
scripted fixtures, and a one-shot runner records each fenced handoff. Authentication
and operational network delivery services are not implemented or deployed.

The value objects preserve raw message octets and content hashes, keep the private
envelope independent of visible headers, and reject Bcc/Resent-Bcc in finalized
outbound root headers without rewriting bytes. See [the boundary contract](docs/message-boundary.md).

## Development

Requires Perl 5.40 or newer, a C compiler/build tools for CPAN dependencies,
`cpanm`, Git, Bash and GNU-compatible tar. The Net::Blossom dependency chain
also needs GMP headers/libraries (`libgmp-dev` on Debian/Ubuntu); CI installs
them explicitly. It does not require an unpublished auth branch or bootstrap.

```sh
bash scripts/install-deps.sh
bash scripts/check.sh all
```

Normal install tests use Test2::V0 and are all directly under `t/`, so the
unchanged upstream coverage collector includes every test. `make test` and
`prove -rlv t` are both supported. Author checks remain under `xt/author/`.

CI tests Perl 5.40 and the latest stable Perl, builds/tests the source tarball,
checks the original custom Perl::Critic policies, and requires per-application-file
coverage of at least **95% statements, 85% branches, and 100% subroutines**.
Missing quality dependencies fail before optional upstream templates can skip.
Coverage applies to value objects and transactional local acceptance, including
process-interruption recovery. It is not evidence that production SMTP transport,
ordinary-client interoperability or a deployed mail service exists.

The complete upstream style package and five author templates are vendored at
an immutable revision. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
Root policy/template copies are checked byte-for-byte. No hooks are installed
automatically; the upstream hook installer is available for opt-in local use.

Mutation testing is manual-only, isolated, scoped to explicit `lib/*.pm` targets,
and allows zero unreviewed survivors. Use it for behavioral modules with a focused suite and inspect every survivor.

```sh
OVERNET_MUTATION_FILES=lib/Overnet/Mail/RawMessage.pm \
OVERNET_MUTATION_TEST_COMMAND='prove -Ilib t/raw-message.t' \
  bash scripts/check.sh mutation
```

Never copy another project's mutation-survivor allowlist.

## Shared storage foundation

Net::Blossom’s SQLite BlobStore and MetadataStore now own byte storage and blob
metadata. Mail-specific records and the recipient outbox share their DBI handle
and one atomic transaction. No Blossom HTTP server, public blob URLs or second
mail authority are introduced. See [the integration contract](docs/blossom-storage.md).
New databases use schema version 3; version 1 and 2 files are rejected unchanged
until an explicit backed-up migration is available. PostgreSQL is not supported
by this mail adapter yet.

## Architecture and next milestone

See [the local storage contract](docs/local-storage.md),
[initial contracts](docs/architecture.md) and
[compatibility acceptance matrix](docs/compatibility.md). Local acceptance is now
transactional, with a [bounded per-recipient outbox](docs/transactional-outbox.md).
A [local SMTP adapter](docs/local-smtp-adapter.md) now tests the handoff boundary
using Net::SMTP. A [one-shot delivery runner](docs/local-delivery-runner.md) joins
that adapter to the durable outbox with explicit crash and completion ambiguity.
Authentication and production transport adapters remain next, followed by tested
native and Internet interoperability. Reuse maintained CPAN libraries and
existing MTA and mailbox servers instead of implementing their protocols from scratch.

## License

GPL-3.0-only. Copied upstream licenses and notices are retained. See `LICENSE`.

## AI assistance

This code was developed with AI assistance and requires normal review and tests.
