#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
ROUTE="$HERE/../route.sh"

# Known error code -> its specialist + primary reference.
out="$(bash "$ROUTE" CANNOT_SCHEDULE_TASK)"; rc=$?
assert_rc "known code exits 0" 0 "$rc"
assert_contains "known code names specialist" "$out" "altinity-expert-clickhouse-metrics"
assert_contains "known code names reference" "$out" "references/query-state.md"

# Case-insensitive keyword match.
out="$(bash "$ROUTE" KAFKA)"
assert_contains "keyword is case-insensitive" "$out" "altinity-expert-clickhouse-kafka"

# Grant keyword resolves.
out="$(bash "$ROUTE" grant)"
assert_contains "grant keyword resolves" "$out" "altinity-expert-clickhouse-grants"

# A docs-covered symptom surfaces its docs-MCP path alongside reference+specialist.
out="$(bash "$ROUTE" TOO_MANY_PARTS)"
assert_contains "docs-covered code names a docs path" "$out" "docs: /"

# A docs-UNCOVERED code says so explicitly rather than staying silent — silence
# reads as "not checked yet" and invites an open-ended docs search, which for a
# bare error code returns Cloud-API noise (see references/docs-lookup.md).
out="$(bash "$ROUTE" KEEPER_EXCEPTION)"
assert_contains "docs-uncovered code says source-confirm only" "$out" "docs: none"
assert_not_contains "docs-uncovered code offers no path" "$out" "docs: /"

# Unknown term -> overview fallback hint on stderr, exit 0.
err="$(bash "$ROUTE" ZZZ_NO_SUCH_THING 2>&1)"; rc=$?
assert_rc "unknown term exits 0" 0 "$rc"
assert_contains "unknown term suggests overview" "$err" "altinity-expert-clickhouse-overview"

finish "route.test.sh"
