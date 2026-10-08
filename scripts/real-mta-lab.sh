#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# No host mounts, published ports, privileged mode, host networking, or credentials.
name="overnet-real-mta-${GITHUB_RUN_ID:-local}-$$"
image="$name:lab"
cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker image rm "$image" >/dev/null 2>&1 || true
}
trap cleanup EXIT
case "${1:-check}" in
  check)
    timeout --kill-after=30s 1200s docker build -f lab/real-mta/Dockerfile -t "$image" .
    docker image inspect "$image" --format '{{.Id}}'
    timeout --kill-after=10s 240s docker run --name "$name" --network none \
      --pids-limit 128 --memory 1g --cpus 2 "$image" check
    ;;
  *) echo 'Usage: scripts/real-mta-lab.sh [check]' >&2; exit 2 ;;
esac
