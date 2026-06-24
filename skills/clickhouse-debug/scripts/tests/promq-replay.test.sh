#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
. "$HERE/../_fixture.sh"
PROMQ="$HERE/../promq.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# Instant-mode logical key is "promq|up|instant||".
mkdir -p "$tmp/fx"
key="$(_fixture_key promq "up|instant||")"
printf 'VALUE          SERIES\n1.0000         instance=ch-07\n' > "$tmp/fx/$key.tsv"

out="$(CH_REPLAY_DIR="$tmp/fx" bash "$PROMQ" 'up')"; rc=$?
assert_rc "instant replay hit exits 0" 0 "$rc"
assert_contains "instant replay body" "$out" "instance=ch-07"

# Range-mode key uses effective span/step, NOT resolved epochs.
keyr="$(_fixture_key promq "node_mem|range|1h|60s")"
printf 'AVG  MAX  SERIES\n' > "$tmp/fx/$keyr.tsv"
out="$(CH_REPLAY_DIR="$tmp/fx" bash "$PROMQ" 'node_mem' range 1h 60s)"; rc=$?
assert_rc "range replay hit exits 0" 0 "$rc"
assert_contains "range replay body" "$out" "SERIES"

# Miss exits 3.
err="$(CH_REPLAY_DIR="$tmp/fx" bash "$PROMQ" 'nope' 2>&1)"; rc=$?
assert_rc "replay miss exits 3" 3 "$rc"
assert_contains "miss names query" "$err" "nope"

finish "promq-replay.test.sh"
