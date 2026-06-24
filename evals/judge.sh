#!/usr/bin/env bash
# Score a diagnosis transcript against a scenario rubric using an LLM judge.
# Usage: judge.sh <scenario-dir> <transcript-file>
# Judge command is injectable for testing: EVAL_JUDGE_CMD (default: claude -p).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

scn="${1:-}"; transcript="${2:-}"
if [ -z "$scn" ] || [ -z "$transcript" ]; then
  echo "usage: judge.sh <scenario-dir> <transcript-file>" >&2; exit 2
fi
[ -f "$scn/rubric.md" ] || { echo "judge.sh: no rubric at $scn/rubric.md" >&2; exit 2; }
[ -f "$transcript" ]    || { echo "judge.sh: no transcript at $transcript" >&2; exit 2; }

payload="$(
  cat "$HERE/judge-prompt.md"
  printf '\n\n===== RUBRIC =====\n\n'; cat "$scn/rubric.md"
  printf '\n\n===== TRANSCRIPT =====\n\n'; cat "$transcript"
)"

printf '%s' "$payload" | ${EVAL_JUDGE_CMD:-claude -p}
