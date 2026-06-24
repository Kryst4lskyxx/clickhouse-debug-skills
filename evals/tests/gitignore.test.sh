#!/usr/bin/env bash
# Verifies the selective evals/ ignore: local/ ignored, harness/scenarios tracked.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

fail=0
# evals/local/ MUST be ignored
if ! git check-ignore -q evals/local/raw.tsv; then
  echo "FAIL: evals/local/ should be ignored"; fail=1
fi
# harness + scenarios MUST NOT be ignored
for p in evals/run.sh evals/scenarios/range-join-oom/prompt.md; do
  if git check-ignore -q "$p"; then
    echo "FAIL: $p should be tracked, not ignored"; fail=1
  fi
done
[ "$fail" -eq 0 ] && echo "PASS: gitignore.test.sh"
exit "$fail"
