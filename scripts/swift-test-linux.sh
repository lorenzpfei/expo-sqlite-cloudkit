#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
image="expo-sqlite-cloudkit-swift:6.2"

if ! docker image inspect "$image" >/dev/null 2>&1; then
  docker build -t "$image" - <<'DOCKERFILE'
FROM swift:6.2
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-dev && rm -rf /var/lib/apt/lists/*
DOCKERFILE
fi

docker run --rm \
  --user "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  -v "$root:/workspace" \
  -w /workspace/packages/sync-core \
  "$image" \
  swift test "$@"
