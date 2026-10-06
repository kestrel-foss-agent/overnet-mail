# Overnet Mail

A Perl email application built around ordinary Internet email compatibility.

**Status: development foundation only.** The first milestone reuses Overnet's
existing Perl quality tooling before any application functionality. No SMTP,
mailbox, authentication, or delivery service is implemented or deployed yet.

## Development

Requires Perl 5.40 or newer, a C compiler/build tools for CPAN dependencies,
`cpanm`, Git, Bash and GNU-compatible tar.

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
The current module is only a version/POD scaffold; high coverage at this stage
is not evidence that email functionality exists or is tested.

The complete upstream style package and five author templates are vendored at
an immutable revision. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
Root policy/template copies are checked byte-for-byte. No hooks are installed
automatically; the upstream hook installer is available for opt-in local use.

Mutation testing is manual-only, isolated, scoped to explicit `lib/*.pm` targets,
and allows zero unreviewed survivors. It is intended for behavioral modules as
they are added; this version-only scaffold has no meaningful mutation score.

```sh
OVERNET_MUTATION_FILES=lib/Overnet/Example.pm \
OVERNET_MUTATION_TEST_COMMAND='prove -Ilib t/example.t' \
  bash scripts/check.sh mutation
```

The example target does not exist yet. Select real application modules before
running the command. Never copy another project's mutation-survivor allowlist.

## Architecture and next milestone

See [the initial contracts](docs/architecture.md) and
[compatibility acceptance matrix](docs/compatibility.md). Next comes a durable
single-authority mailbox and transactional outbox, followed by tested native and
Internet interoperability. Reuse maintained CPAN libraries and existing MTA and
mailbox servers instead of implementing their protocols from scratch.

## License

GPL-3.0-only. Copied upstream licenses and notices are retained. See `LICENSE`.

## AI assistance

This code was developed with AI assistance and requires normal review and tests.
