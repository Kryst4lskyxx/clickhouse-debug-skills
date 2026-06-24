#!/usr/bin/env bash
# Run every *.test.sh in this dir; non-zero exit if any fails.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fails=0
for t in "$HERE"/*.test.sh; do
  echo "== $(basename "$t") =="
  bash "$t" || fails=1
done
exit "$fails"
