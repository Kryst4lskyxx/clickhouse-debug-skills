#!/usr/bin/env bash
# Look up which reference playbook + altinity specialist + ClickHouse-docs page to
# use for an error code or symptom keyword. Reads references/routing.tsv (the single
# source of truth); the SKILL.md routing table is the human view of the same map.
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
    if (index(p, t) > 0 || index(t, p) > 0) {
      # docs_path "-" means the docs have no usable page for this symptom. Say so
      # out loud: silence reads as "not looked up yet" and invites an open-ended
      # docs search, which for a bare error code returns noise, not an answer.
      #
      # "if a trigger applies" is load-bearing, not hedging. This line is a
      # bookmark, not an instruction — printing a path on every lookup would turn
      # route.sh into a standing invitation to read docs, which is the opposite of
      # the named-trigger rule in SKILL.md.
      d = ($5 == "-") ? "none — source-confirm only" : $5 "  (only if a trigger applies)"
      printf "%s\t-> %s + Skill: %s  (%s)\n\tdocs: %s\n", $1, $2, $3, $4, d
    }
  }' "$TSV")"

if [ -n "$matches" ]; then
  printf '%s\n' "$matches"
else
  echo "route.sh: no routing match for '$term' — start with altinity-expert-clickhouse-overview (health snapshot), then re-route." >&2
fi
