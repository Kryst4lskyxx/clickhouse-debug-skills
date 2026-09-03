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

# Schema guard: every row carries all 5 columns, docs_path last.
assert_eq "header is the 5-column schema" \
  "pattern	primary_reference	specialist	note	docs_path" "$(head -1 "$TSV")"

bad_width="$(awk -F'\t' 'NF != 5 { print NR": "NF" fields" }' "$TSV")"
assert_eq "every row has exactly 5 tab-separated fields" "" "$bad_width"

# docs_path is either an absolute docs-MCP path or an explicit "-" meaning the
# docs have no usable page for this symptom (source-confirm only). An empty cell
# is a drift bug, not a valid "no coverage" answer — the "-" must be deliberate.
bad_docs="$(tail -n +2 "$TSV" | cut -f5 \
  | awk '$0 != "-" && $0 !~ /^\// { print "bad docs_path: ["$0"]" }')"
assert_eq "docs_path is an absolute path or an explicit '-'" "" "$bad_docs"

# The codes the docs provably cannot answer must be marked "-", so the routing
# table never sends the agent to a page that will return Cloud-API noise.
for code in CANNOT_SCHEDULE_TASK KEEPER_EXCEPTION; do
  got="$(awk -F'\t' -v c="$code" '$1 == c { print $5 }' "$TSV")"
  assert_eq "$code is marked docs-uncovered" "-" "$got"
done

finish "routing.test.sh"
