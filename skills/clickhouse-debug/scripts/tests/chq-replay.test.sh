#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
. "$HERE/../_fixture.sh"
CHQ="$HERE/../chq.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# Seed a fixture for "SELECT 1".
mkdir -p "$tmp/fx"
key="$(_fixture_key chq "SELECT 1")"; printf '1\n' > "$tmp/fx/$key.tsv"

# Replay hit needs NO CH_URL/creds and never hits the network.
out="$(CH_REPLAY_DIR="$tmp/fx" bash "$CHQ" "SELECT 1")"; rc=$?
assert_rc "replay hit exits 0" 0 "$rc"
assert_eq "replay hit body" "1" "$out"

# Replay miss exits 3 with the query echoed.
err="$(CH_REPLAY_DIR="$tmp/fx" bash "$CHQ" "SELECT 2" 2>&1)"; rc=$?
assert_rc "replay miss exits 3" 3 "$rc"
assert_contains "miss names query" "$err" "SELECT 2"

# Capture: stub curl on PATH so no real network is needed.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf 'STUBBED-OK\n'
STUB
chmod +x "$tmp/bin/curl"
PATH="$tmp/bin:$PATH" CH_URL="http://x:8123" CH_CAPTURE_DIR="$tmp/cap" \
  bash "$CHQ" "SELECT 1" >/dev/null
assert_eq "captured stub body" "STUBBED-OK" "$(cat "$tmp/cap/$key.tsv")"

finish "chq-replay.test.sh"
