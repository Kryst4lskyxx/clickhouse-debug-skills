#!/usr/bin/env bash
# Drive a subagent through one scenario in replay mode and save its transcript.
# Usage: run.sh <scenario-dir> [transcript-out]
# Agent command is injectable for testing: EVAL_AGENT_CMD (default: claude -p).
set -euo pipefail

scn="${1:-}"
if [ -z "$scn" ] || [ ! -d "$scn" ]; then
  echo "usage: run.sh <scenario-dir> [transcript-out]   (scenario dir not found)" >&2
  exit 2
fi
[ -f "$scn/prompt.md" ] || { echo "run.sh: no prompt.md in $scn" >&2; exit 2; }
out="${2:-$scn/last-transcript.txt}"

# Optional source-version sanity check (the skill confirms against matched source).
if [ -n "${CH_SRC:-}" ] && [ -f "$scn/meta.yaml" ]; then
  want="$(sed -n 's/^version:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "$scn/meta.yaml")"
  have="$(git -C "$CH_SRC" describe --tags 2>/dev/null || echo unknown)"
  case "$have" in *"$want"*) ;; *) echo "run.sh: WARNING CH_SRC at [$have] != scenario version [$want]" >&2;; esac
fi

export CH_REPLAY_DIR="$(cd "$scn/fixtures" && pwd)"

prompt="$(
  cat <<'PREAMBLE'
You are debugging a ClickHouse incident using the clickhouse-debug skill.
The probe scripts (chq.sh / promq.sh) are in REPLAY mode: they return canned
fixtures and never touch a network, so run them exactly as the skill instructs.
A replay miss (exit 3, "no fixture for: ...") means you tried a probe the
scenario did not capture — note it and continue with what you can confirm.
Produce a full root-cause writeup in the skill's RCA format.

--- INCIDENT ---
PREAMBLE
  cat "$scn/prompt.md"
)"

printf '%s' "$prompt" | ${EVAL_AGENT_CMD:-claude -p} | tee "$out"
echo "run.sh: transcript -> $out" >&2
