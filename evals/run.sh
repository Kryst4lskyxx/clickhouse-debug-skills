#!/usr/bin/env bash
# Drive a subagent through one scenario in replay mode and save its transcript.
# Usage: run.sh <scenario-dir> [transcript-out]
# Agent command is injectable for testing: EVAL_AGENT_CMD (default: claude -p ...).
#
# For a FAITHFUL headless run the agent must (a) stand in the matched ClickHouse
# source tree to confirm the mechanism (set CH_SRC), (b) use THIS repo's
# replay-enabled probe scripts (their absolute paths are injected into the prompt),
# and (c) follow the clickhouse-debug method (SKILL.md path injected). With CH_SRC
# unset the agent cannot satisfy a source-confirmation rubric criterion.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="$REPO_ROOT/skills/clickhouse-debug/scripts"
SKILL_MD="$REPO_ROOT/skills/clickhouse-debug/SKILL.md"

scn="${1:-}"
if [ -z "$scn" ] || [ ! -d "$scn" ]; then
  echo "usage: run.sh <scenario-dir> [transcript-out]   (scenario dir not found)" >&2
  exit 2
fi
[ -f "$scn/prompt.md" ] || { echo "run.sh: no prompt.md in $scn" >&2; exit 2; }
[ -d "$scn/fixtures" ] || { echo "run.sh: no fixtures/ in $scn" >&2; exit 2; }
out="${2:-$scn/last-transcript.txt}"

# Optional source-version sanity check (the skill confirms against matched source).
if [ -n "${CH_SRC:-}" ] && [ -f "$scn/meta.yaml" ]; then
  want="$(sed -n 's/^version:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "$scn/meta.yaml")"
  have="$(git -C "$CH_SRC" describe --tags 2>/dev/null || echo unknown)"
  case "$have" in *"$want"*) ;; *) echo "run.sh: WARNING CH_SRC at [$have] != scenario version [$want]" >&2;; esac
fi
if [ -z "${CH_SRC:-}" ]; then
  echo "run.sh: WARNING CH_SRC unset — the agent cannot confirm against source (a source-confirmation criterion will fail)." >&2
fi

export CH_REPLAY_DIR="$(cd "$scn/fixtures" && pwd)"

prompt="$(
  cat <<PREAMBLE
You are debugging a ClickHouse incident using the clickhouse-debug skill, running NON-INTERACTIVELY.

METHOD: read and follow $SKILL_MD and the references/ beside it (cluster-state.md, query-state.md, source-map.md, keeper-state.md).

SOURCE: your working directory is a ClickHouse source tree checked out at the cluster's version — confirm the mechanism by grepping it and cite file:line. (If this is not a source tree, say so and proceed; the source-confirmation step cannot be completed.)

TELEMETRY (REPLAY MODE — canned fixtures, read-only, no network). Run exactly:
  $SCRIPTS/chq.sh "SELECT ..."
  $SCRIPTS/promq.sh 'PROMQL' [range SPAN STEP]
CH_REPLAY_DIR is exported, so these return fixtures for the probes this scenario captured. A "no fixture for: ..." miss (exit 3) means that probe was not captured — note it and continue; do NOT conclude the cluster is down.

Produce a full root-cause writeup in the skill's RCA format (Root cause / Evidence / Fix / Severity & scope).

--- INCIDENT ---
PREAMBLE
  cat "$scn/prompt.md"
)"

echo "run.sh: transcript -> $out" >&2
runfrom="${CH_SRC:-$PWD}"
( cd "$runfrom" && printf '%s' "$prompt" | ${EVAL_AGENT_CMD:-claude -p --allowedTools Bash,Read,Grep,Glob} ) | tee "$out"
