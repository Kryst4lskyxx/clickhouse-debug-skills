#!/usr/bin/env bash
# Look up which reference playbook + altinity specialist to use for an error code
# or symptom keyword. Reads references/routing.tsv (the single source of truth);
# the SKILL.md routing table is the human view of the same map.
#
# Usage:
#   ./route.sh CANNOT_SCHEDULE_TASK
#   ./route.sh cache
#
# Matching is case-insensitive and substring-based in BOTH directions, so an error
# code matches its row and a longer phrase ("slow INSERT") still matches "INSERT".
# No match -> a hint to start from the overview specialist (exit 0, hint on stderr).

set -euo pipefail

term="${1:?usage: route.sh <error-code-or-keyword>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TSV="$SCRIPT_DIR/../references/routing.tsv"
[ -f "$TSV" ] || { echo "route.sh: missing $TSV" >&2; exit 2; }

lc="$(printf '%s' "$term" | tr '[:upper:]' '[:lower:]')"
matches="$(awk -F'\t' -v t="$lc" '
  NR==1 { next }
  {
    p = tolower($1)
    if (index(p, t) > 0 || index(t, p) > 0)
      printf "%s\t-> %s + Skill: %s  (%s)\n", $1, $2, $3, $4
  }' "$TSV")"

if [ -n "$matches" ]; then
  printf '%s\n' "$matches"
else
  echo "route.sh: no routing match for '$term' — start with altinity-expert-clickhouse-overview (health snapshot), then re-route." >&2
fi
