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

# Unknown term -> overview fallback hint on stderr, exit 0.
err="$(bash "$ROUTE" ZZZ_NO_SUCH_THING 2>&1)"; rc=$?
assert_rc "unknown term exits 0" 0 "$rc"
assert_contains "unknown term suggests overview" "$err" "altinity-expert-clickhouse-overview"

finish "route.test.sh"
