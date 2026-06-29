#!/usr/bin/env bash
# Drift guard: the set of specialists in routing.tsv (col 3) must equal the set of
# altinity-expert-clickhouse-* skills named in the SKILL.md routing table. Table
# rows are markdown rows (contain '|'); prose mentions don't, so '|' isolates them.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
SKILL="$HERE/../../SKILL.md"
TSV="$HERE/../../references/routing.tsv"

table_specialists="$(grep 'altinity-expert-clickhouse-' "$SKILL" | grep '|' \
  | grep -oE 'altinity-expert-clickhouse-[a-z-]+' | sort -u)"
tsv_specialists="$(tail -n +2 "$TSV" | cut -f3 | sort -u)"

assert_eq "routing.tsv specialists == SKILL.md table specialists" \
  "$table_specialists" "$tsv_specialists"

finish "routing.test.sh"
