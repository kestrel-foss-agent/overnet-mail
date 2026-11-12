#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# No host mounts, published ports, privileged mode, host networking, or secrets.
# Dependencies are built once with network access; all tests run without it.
name="overnet-inbound-mta-${GITHUB_RUN_ID:-local}-$$"
image="$name:lab"
cleanup() {
  timeout --kill-after=5s 30s docker rm -f "$name" >/dev/null 2>&1 || true
  timeout --kill-after=5s 30s docker image rm "$image" >/dev/null 2>&1 || true
}
case "${1:-check}" in
  check)
    [[ $# -le 1 ]] || { echo 'Usage: scripts/inbound-mta-lab.sh [check]' >&2; exit 2; }
    command -v docker >/dev/null
    command -v timeout >/dev/null
    trap cleanup EXIT
    timeout --kill-after=30s 1200s docker build -f lab/inbound-mta/Dockerfile -t "$image" .
    docker image inspect "$image" --format '{{.Id}}'
    timeout --kill-after=10s 660s docker run --name "$name" --network none \
      --pids-limit 128 --memory 1g --cpus 2 "$image" check
    ;;
  *) echo 'Usage: scripts/inbound-mta-lab.sh [check]' >&2; exit 2 ;;
esac
