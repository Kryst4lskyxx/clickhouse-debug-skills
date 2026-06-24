#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
. "$ROOT/../skills/clickhouse-debug/scripts/tests/assert.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# Minimal scenario dir with a rubric.
mkdir -p "$tmp/scn"
printf '1. (critical) mechanism identified\n' > "$tmp/scn/rubric.md"
printf 'The root cause is a range JOIN.\n' > "$tmp/transcript.txt"

# Stub judge: echoes back its stdin so we can assert assembly.
export EVAL_JUDGE_CMD="cat"

out="$(bash "$ROOT/judge.sh" "$tmp/scn" "$tmp/transcript.txt")"; rc=$?
assert_rc "judge exits 0" 0 "$rc"
assert_contains "includes rubric" "$out" "mechanism identified"
assert_contains "includes transcript" "$out" "range JOIN"
assert_contains "includes judge instructions" "$out" "OVERALL:"

# Missing args -> exit 2.
bash "$ROOT/judge.sh" "$tmp/scn" 2>/dev/null; assert_rc "missing transcript exits 2" 2 "$?"

# --- run.sh ---
mkdir -p "$tmp/scn/fixtures"
printf 'Investigate the OOM on ch-07.\n' > "$tmp/scn/prompt.md"
printf 'version: "25.8.11.66-lts"\n' > "$tmp/scn/meta.yaml"

# Stub agent: prove the harness exported CH_REPLAY_DIR and passed the prompt in.
cat > "$tmp/agent" <<'STUB'
#!/usr/bin/env bash
echo "REPLAY=$CH_REPLAY_DIR"
echo "PROMPT-IN: $(cat)"
STUB
chmod +x "$tmp/agent"

out_file="$tmp/out.txt"
EVAL_AGENT_CMD="$tmp/agent" bash "$ROOT/run.sh" "$tmp/scn" "$out_file" >/dev/null; rc=$?
assert_rc "run exits 0" 0 "$rc"
assert_contains "exported replay dir" "$(cat "$out_file")" "fixtures"
assert_contains "passed the prompt" "$(cat "$out_file")" "Investigate the OOM"

bash "$ROOT/run.sh" "$tmp/missing" 2>/dev/null; assert_rc "missing scenario exits 2" 2 "$?"

finish "harness.test.sh"
