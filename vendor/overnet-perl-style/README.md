# overnet-perl-style

Shared [Perl::Critic](https://metacpan.org/pod/Perl::Critic), [Perl::Tidy](https://metacpan.org/pod/Perl::Tidy), author tests, hooks, and CI tooling for Overnet Perl distributions.

This keeps the Overnet Perl distributions on the same style and quality contract.

## Layout

- [`configs/`](configs/) - shared configs, hooks, author test templates, and CI examples.
- [`lib/Perl/Critic/Policy/Overnet/`](lib/Perl/Critic/Policy/Overnet/) - custom Perl::Critic policies.
- [`tools/`](tools/) - scripts that sync or install the shared configs.

## Usage

Install this package into the active Perl:

```bash
cpanm .
```

Sync the shared profiles and author tests into some repos:

```bash
./tools/sync-configs /path/to/perl-repo /path/to/another-perl-repo
```

Install the shared local pre-commit hook:

```bash
./tools/install-git-hooks /path/to/perl-repo /path/to/another-perl-repo
```

## Custom Perl::Critic Policies

- [`RequireStrictures2`](lib/Perl/Critic/Policy/Overnet/RequireStrictures2.pm) requires `use strictures 2;`.
- [`RequireJSONEmptyImport`](lib/Perl/Critic/Policy/Overnet/RequireJSONEmptyImport.pm) requires `use JSON ();` when JSON is imported.
- [`RequireTest2InTests`](lib/Perl/Critic/Policy/Overnet/RequireTest2InTests.pm) requires `.t` files to use `Test2::V0` and prohibits `Test::More`.
- [`ProhibitBless`](lib/Perl/Critic/Policy/Overnet/ProhibitBless.pm) prohibits direct `bless` calls so Overnet OO code uses Moo-owned construction instead of hand-rolled blessed objects.
- [`ProhibitNewConstructor`](lib/Perl/Critic/Policy/Overnet/ProhibitNewConstructor.pm) prohibits defining constructors with `sub new` or installing them through `*new = ...`; normal `Class->new(...)` calls remain allowed.
- [`RequireMooConstructorArgsNormalization`](lib/Perl/Critic/Policy/Overnet/RequireMooConstructorArgsNormalization.pm) prohibits destructuring `BUILDARGS` or `around new` constructor wrapper arguments directly into `%args`; capture `@args` first so Moo's hashref constructor form stays supported.

## Notes

- Style and POD gates belong in `xt/author/`, not normal install tests under `t/`.
- The [`devel-cover.t`](configs/test-templates/xt/author/devel-cover.t) template is an opt-in [Devel::Cover](https://metacpan.org/pod/Devel::Cover) gate: it runs only when `OVERNET_COVERAGE=1` is set and enforces per-file floors over `lib/` of 95% statement, 85% branch, and 100% subroutine coverage. Every module under `lib/` is loaded during collection, so a module the suite never touches is judged by the floors instead of silently escaping them, and instrumentation passes `-blib,0` so a stale `blib/` directory cannot hijack collection onto built copies. Repos below a floor set `OVERNET_COVERAGE_MIN_STATEMENT`, `OVERNET_COVERAGE_MIN_BRANCH`, or `OVERNET_COVERAGE_MIN_SUBROUTINE` in their coverage CI job as a ratchet — pinned at the current watermark, raised as tests improve, never lowered; the synced template itself must stay unedited.
- The [`mutation.t`](configs/test-templates/xt/author/mutation.t) template is a manual [Devel::Mutator](https://metacpan.org/pod/Devel::Mutator) gate: where coverage asks "did a test run this line?", mutation asks "would a test notice if this line were wrong?". It reruns the suite once per mutant, so it never runs by default — it skips unless `OVERNET_MUTATION=1` and an explicit `OVERNET_MUTATION_FILES` target list are set (and Devel::Mutator is installed: `cpanm Devel::Mutator`). It mutates in a throwaway copy beside the repo so an interrupted run cannot corrupt the source, and fails on any *unreviewed* surviving mutant. Scope it to the modules that matter, e.g. `OVERNET_MUTATION=1 OVERNET_MUTATION_FILES=lib/Overnet/Authority/Delegation.pm OVERNET_MUTATION_TEST_COMMAND='prove -Ilib t/authority-delegation.t' perl -Ilib xt/author/mutation.t`. A surviving mutant a human has judged equivalent or intentional (e.g. an unobservable change) is pinned individually in an allowlist file (default `xt/author/mutation-allow.txt`, override with `OVERNET_MUTATION_ALLOW`): on failure the gate prints each survivor as a paste-ready `-`/`+` diff block, and adding that block to the allowlist accepts exactly that mutant while any *new* survivor still fails the gate — so an accepted equivalent can never mask a fresh real gap. Tune with `OVERNET_MUTATION_TIMEOUT` and `OVERNET_MUTATION_MAX_SURVIVORS` (a blunt tolerated count of unreviewed survivors, normally left at 0 in favour of the allowlist). Each Overnet Perl repo also ships a manual [`mutation.yml`](configs/github-actions/mutation.yml) GitHub Actions workflow (`workflow_dispatch` only, never on push/PR) so the same gate can be launched on demand from the Actions tab with `files`, `test_command`, `timeout`, and `max_survivors` inputs.
- [`tools/sync-configs`](tools/sync-configs) copies configs and author test templates; it does not install the custom policy modules.
- [`Makefile.PL`](Makefile.PL) is this repo's package metadata and a useful template shape for other Overnet Perl repos.

## AI Usage

This code was developed in part with AI tooling such as Claude Code and Codex. We want to be upfront about that.
