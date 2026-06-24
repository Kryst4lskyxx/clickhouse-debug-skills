#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
. "$HERE/../_fixture.sh"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# 1. Key is stable across cosmetic whitespace differences.
k1="$(_fixture_key chq "SELECT  1")"
k2="$(_fixture_key chq "SELECT 1")"
assert_eq "whitespace-insensitive key" "$k1" "$k2"

# 2. Different script namespaces don't collide.
kq="$(_fixture_key promq "SELECT 1")"
[ "$k1" != "$kq" ] || { echo "  FAIL: chq/promq keyspaces collided"; _assert_fails=1; }

# 3. Capture writes a fixture file + index row.
CH_CAPTURE_DIR="$tmp/cap" fixture_capture chq "SELECT 1" "RESULT-BODY"
key="$(_fixture_key chq "SELECT 1")"
assert_eq "captured body" "RESULT-BODY" "$(cat "$tmp/cap/$key.tsv")"
assert_contains "index has key" "$(cat "$tmp/cap/index.tsv")" "$key"

# 4. Replay hit prints the body and returns 0.
out="$(CH_REPLAY_DIR="$tmp/cap" fixture_replay chq "SELECT 1")"; rc=$?
assert_rc "replay hit rc" 0 "$rc"
assert_eq "replay body" "RESULT-BODY" "$out"

# 5. Replay miss returns 2 and reports the query.
err="$(CH_REPLAY_DIR="$tmp/cap" fixture_replay chq "SELECT 999" 2>&1)"; rc=$?
assert_rc "replay miss rc" 2 "$rc"
assert_contains "miss message" "$err" "no fixture for: SELECT 999"

# 6. Replay inactive (no dir) returns 1.
( unset CH_REPLAY_DIR; fixture_replay chq "SELECT 1" ); assert_rc "replay inactive rc" 1 "$?"

finish "fixture.test.sh"
