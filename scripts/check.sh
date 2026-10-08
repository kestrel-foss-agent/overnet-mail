#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-all}" in
  test)
    perl Makefile.PL
    make test
    prove -rlv t
    ;;
  author)
    perl -MPerl::Critic -MPerl::Tidy -MTest::Perl::Critic -MTest::Pod -MTest::Pod::Coverage -e 1
    perl -MPerl::Critic::Policy::Overnet::RequireStrictures2 -MPerl::Critic::Policy::Overnet::RequireTest2InTests -e 1
    # Explicit paths prevent an existing blib/ from shadowing source checks.
    perlcritic --profile .perlcriticrc --severity 1 --only lib
    perlcritic --profile .perlcriticrc --single-policy Overnet::RequireTest2InTests t xt/author xt/integration
    prove -rlv xt/author
    # These exercise positive and negative custom-policy behavior.
    (cd vendor/overnet-perl-style && prove -rlv t)
    bash -n scripts/*.sh lab/real-mta/control
    ;;
  coverage)
    # The shared template skips if its dependency is missing. CI must fail.
    perl -e 'require Devel::Cover; require Devel::Cover::DB'
    export OVERNET_COVERAGE=1
    export OVERNET_COVERAGE_MIN_STATEMENT=95
    export OVERNET_COVERAGE_MIN_BRANCH=85
    export OVERNET_COVERAGE_MIN_SUBROUTINE=100
    prove -lv xt/author/devel-cover.t
    ;;
  mutation)
    perl -MDevel::Mutator::Command::Mutate -MDevel::Mutator::Command::Test -e 1
    : "${OVERNET_MUTATION_FILES:?Select existing lib/ modules to mutate}"
    targets=${OVERNET_MUTATION_FILES//:/ }
    set -f
    target_count=0
    for target in $targets; do
      ((target_count += 1))
      case "$target" in
        lib/*.pm) ;;
        *) echo "Invalid mutation target: $target" >&2; exit 1 ;;
      esac
      case "$target" in *..*) echo 'Path traversal is not allowed' >&2; exit 1 ;; esac
      test -f "$target"
    done
    if ((target_count == 0)); then
      echo 'Select at least one mutation target' >&2
      exit 1
    fi
    export OVERNET_MUTATION=1
    export OVERNET_MUTATION_MAX_SURVIVORS=0
    prove -lv xt/author/mutation.t
    ;;
  dist)
    # ExtUtils::Manifest's make distcheck target only warns; reject omissions.
    perl -MExtUtils::Manifest=manicheck,filecheck -e 'my @bad = (manicheck(), filecheck()); exit(@bad ? 1 : 0)'
    perl Makefile.PL
    make distcheck
    make disttest
    ;;
  all)
    for check in test author coverage dist; do
      bash "$0" "$check"
    done
    ;;
  *) echo 'Usage: scripts/check.sh [all|test|author|coverage|mutation|dist]' >&2; exit 2 ;;
esac
