#!/usr/bin/env bash
set -euo pipefail
: "${1:?Supply a temporary directory for generated Linux syscall definitions}"
mkdir -p "$1"
# Use this Perl's core converter and the compiler's actual platform headers.
# Nothing is installed into Perl's global libraries and no syscall is guessed.
perl "$(command -v h2ph)" -a -d "$1" syscall.h
test -s "$1/syscall.ph"
perl -I"$1" -e 'require "syscall.ph"; die "SYS_prctl is unavailable\n" unless defined &SYS_prctl'
