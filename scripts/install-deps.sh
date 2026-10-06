#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
cpanm --installdeps .
# Audit the pinned source before installing code from the vendored package.
prove -lv t/quality-provenance.t
cpanm Devel::Cover Devel::Mutator Perl::Critic Perl::Tidy Test::Perl::Critic Test::Pod Test::Pod::Coverage
# Syncing profiles does not install the six custom policies.
cpanm ./vendor/overnet-perl-style
