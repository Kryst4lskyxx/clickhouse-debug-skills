# ClickHouse-debug eval harness (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a thin, repeatable fixture-replay eval harness for the `clickhouse-debug` skill — capture/replay modes in the probe scripts, a scenario format, an LLM-judge, and one seeded scenario proven to discriminate good from broken diagnoses.

**Architecture:** Two env-gated modes (`CH_CAPTURE_DIR`, `CH_REPLAY_DIR`) are added to `chq.sh` and `promq.sh` via a shared sourced helper (`_fixture.sh`), leaving normal operation byte-for-byte unchanged when neither is set. The harness (`evals/run.sh`, `evals/judge.sh`) drives a subagent against canned fixtures (replay) and scores its transcript against a per-scenario rubric. The agent command is injectable (`EVAL_AGENT_CMD`/`EVAL_JUDGE_CMD`, default `claude -p`) so the plumbing is unit-testable with a stub and not locked to one CLI.

**Tech Stack:** POSIX/bash shell, `curl`, `jq`, `sha1sum`-or-`shasum` (portable), plain-shell unit tests (no external test framework).

## Global Constraints

Every task's requirements implicitly include this section.

- **Branch:** all work lands on `spec/clickhouse-debug-improvements` (off `main`, which is PR-only). Do not commit to `main`.
- **Read-only invariant:** nothing added may mutate a cluster. Replay/capture touch only the local filesystem.
- **Zero-behavior-change when idle:** with neither `CH_CAPTURE_DIR` nor `CH_REPLAY_DIR` set, `chq.sh`/`promq.sh` must behave exactly as today (the resource caps and retry logic are untouched).
- **No new runtime dependencies** beyond what the scripts already use (`curl`, `jq`) plus `sha1sum` *or* `shasum -a 1` (handle both; macOS ships `shasum`, Linux ships `sha1sum`).
- **Committed fixtures are synthetic or sanitized** — no real hostnames, IPs, tenant IDs, or data values. Raw captures stay in the git-ignored `evals/local/`.
- **Source-confirmation invariant:** any scenario rubric that asserts a mechanism requires a matched-source `file:line` citation criterion.
- **Shell scripts use `set -euo pipefail`** (matching the existing scripts). Helper functions signal misses via return codes, never via a bare nonzero that would trip `set -e` in a caller.
- **Version bump on release:** the capability bump is **0.5.0** (minor = new script/capability per the repo's scheme). Bump all 5 locations via `./scripts/bump-version.sh 0.5.0`.
- **Commits:** conventional-commit format (`feat:`, `test:`, `docs:`, `chore:`). Attribution is disabled globally.
- **Skill-context hygiene:** the eval harness is maintainer-facing. Document it in `README.md`/`CONTRIBUTING.md`, NOT in `SKILL.md` (keep the agent's loaded context lean). The two new env vars get a one-line header note in each script only.

---

## File Structure

**New files:**
- `skills/clickhouse-debug/scripts/_fixture.sh` — shared capture/replay helper (hash, normalize, key, `fixture_replay`, `fixture_capture`).
- `skills/clickhouse-debug/scripts/tests/assert.sh` — tiny shared assertion helpers for shell unit tests.
- `skills/clickhouse-debug/scripts/tests/run.sh` — discovers and runs all `*.test.sh`.
- `skills/clickhouse-debug/scripts/tests/fixture.test.sh` — unit tests for `_fixture.sh`.
- `skills/clickhouse-debug/scripts/tests/chq-replay.test.sh` — unit tests for chq.sh capture/replay.
- `skills/clickhouse-debug/scripts/tests/promq-replay.test.sh` — unit tests for promq.sh capture/replay.
- `evals/README.md` — harness layout + how to run + sanitization rule.
- `evals/run.sh` — scenario runner (replay mode → subagent → transcript).
- `evals/judge.sh` — transcript scorer (rubric + transcript → scorecard).
- `evals/judge-prompt.md` — the judge's scoring instructions.
- `evals/tests/harness.test.sh` — unit tests for run.sh/judge.sh plumbing (stubbed agent).
- `evals/scenarios/range-join-oom/meta.yaml`
- `evals/scenarios/range-join-oom/prompt.md`
- `evals/scenarios/range-join-oom/rubric.md`
- `evals/scenarios/range-join-oom/fixtures/*.tsv` + `index.tsv`

**Modified files:**
- `.gitignore` — replace the blanket `evals/` ignore with a selective rule.
- `skills/clickhouse-debug/scripts/chq.sh` — source helper; replay short-circuit; capture on success; reorder the `CH_URL` requirement below the replay block.
- `skills/clickhouse-debug/scripts/promq.sh` — same pattern; reorder the `PROM` requirement; capture the formatted output.
- `README.md` — add an "Evals" section.
- `CONTRIBUTING.md` — add the fixture-sanitization checklist + "adding a scenario".
- `CHANGELOG.md` — 0.5.0 entry.
- 5 version locations via `bump-version.sh`.

---

## Task 1: Resolve the gitignore tension + evals skeleton

**Files:**
- Modify: `.gitignore:7-13`
- Create: `evals/README.md`
- Create: `evals/local/.gitkeep`

**Interfaces:**
- Produces: a committed `evals/` tree where `evals/local/` stays ignored but the harness + scenarios are tracked. Later tasks add files under `evals/`.

- [ ] **Step 1: Write the failing test**

Create `evals/tests/gitignore.test.sh`:

```bash
#!/usr/bin/env bash
# Verifies the selective evals/ ignore: local/ ignored, harness/scenarios tracked.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

fail=0
# evals/local/ MUST be ignored
if ! git check-ignore -q evals/local/raw.tsv; then
  echo "FAIL: evals/local/ should be ignored"; fail=1
fi
# harness + scenarios MUST NOT be ignored
for p in evals/run.sh evals/scenarios/range-join-oom/prompt.md; do
  if git check-ignore -q "$p"; then
    echo "FAIL: $p should be tracked, not ignored"; fail=1
  fi
done
[ "$fail" -eq 0 ] && echo "PASS: gitignore.test.sh"
exit "$fail"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash evals/tests/gitignore.test.sh`
Expected: FAIL — the current `.gitignore` ignores all of `evals/`, so `evals/run.sh` is reported ignored.

- [ ] **Step 3: Edit `.gitignore`**

Replace the final block (the `evals/` lines, currently `.gitignore:11-13`) with:

```gitignore
# Eval fixtures captured from real clusters contain internal telemetry
# (host names, IPs, tenant refs) — keep raw captures local and untracked.
# The harness, scenarios, and SANITIZED fixtures ARE committed (see evals/README.md).
evals/local/
```

- [ ] **Step 4: Create `evals/local/.gitkeep`**

```bash
mkdir -p evals/local && touch evals/local/.gitkeep
```

Note: `.gitkeep` is itself under `evals/local/` and therefore ignored; it exists only so the dir is present after a fresh clone for `--capture` to write into. (It will NOT be committed — that's fine; document the dir in `evals/README.md` instead.)

Actually commit the placeholder explicitly so the directory survives clone:

```bash
git add -f evals/local/.gitkeep
```

- [ ] **Step 5: Create `evals/README.md`**

```markdown
# clickhouse-debug evals

Fixture-replay harness: run the skill against canned probe output and score the
diagnosis. No live cluster required.

## Layout
- `run.sh <scenario>` — drive a subagent against a scenario's fixtures (replay).
- `judge.sh <scenario> <transcript>` — score a transcript against the rubric.
- `judge-prompt.md` — the judge's scoring instructions.
- `scenarios/<slug>/` — `meta.yaml`, `prompt.md`, `rubric.md`, `fixtures/`.
- `local/` — git-ignored; raw `--capture` output lands here before sanitizing.

## Golden rule
Committed fixtures are **synthetic or sanitized**. Never commit raw cluster
telemetry. See CONTRIBUTING.md for the sanitization checklist.

## Run
    EVAL_AGENT_CMD='claude -p' ./run.sh scenarios/range-join-oom out.txt
    ./judge.sh scenarios/range-join-oom out.txt
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `bash evals/tests/gitignore.test.sh`
Expected: `PASS: gitignore.test.sh` (the test references `evals/run.sh` and a scenario path by string; `git check-ignore` evaluates the path rules, not file existence, so it passes now).

- [ ] **Step 7: Commit**

```bash
git add .gitignore evals/README.md evals/tests/gitignore.test.sh
git add -f evals/local/.gitkeep
git commit -m "chore: track evals harness, keep raw captures in ignored evals/local/"
```

---

## Task 2: Fixture helper library (`_fixture.sh`)

**Files:**
- Create: `skills/clickhouse-debug/scripts/_fixture.sh`
- Create: `skills/clickhouse-debug/scripts/tests/assert.sh`
- Create: `skills/clickhouse-debug/scripts/tests/run.sh`
- Create: `skills/clickhouse-debug/scripts/tests/fixture.test.sh`

**Interfaces:**
- Produces (sourced API, used by Tasks 3–4):
  - `fixture_replay <script> <logical-input>` — prints fixture to stdout + returns `0` on hit; prints `no fixture for: <input>` to stderr + returns `2` on miss (replay active); returns `1` if `CH_REPLAY_DIR` unset.
  - `fixture_capture <script> <logical-input> <output>` — if `CH_CAPTURE_DIR` set, writes `<dir>/<key>.tsv` and appends `<key>\t<normalized-input>` to `<dir>/index.tsv`; returns `0`. No-op (returns `0`) if unset.
  - `<script>` is the literal string `chq` or `promq`. Key = `sha1("<script>|<normalized-input>")`.

- [ ] **Step 1: Write the shared assert helper**

Create `skills/clickhouse-debug/scripts/tests/assert.sh`:

```bash
#!/usr/bin/env bash
# Minimal assertions for shell unit tests. Source this; call assert_* ; finish.
_assert_fails=0
assert_eq() {  # msg expected actual
  if [ "$2" != "$3" ]; then
    echo "  FAIL: $1: expected [$2] got [$3]"; _assert_fails=1
  fi
}
assert_contains() {  # msg haystack needle
  case "$2" in *"$3"*) ;; *) echo "  FAIL: $1: [$2] missing [$3]"; _assert_fails=1;; esac
}
assert_rc() {  # msg expected-rc actual-rc
  if [ "$2" != "$3" ]; then echo "  FAIL: $1: expected rc $2 got $3"; _assert_fails=1; fi
}
finish() {  # name
  if [ "$_assert_fails" -eq 0 ]; then echo "PASS: $1"; else echo "FAILED: $1"; fi
  exit "$_assert_fails"
}
```

- [ ] **Step 2: Write the failing test for `_fixture.sh`**

Create `skills/clickhouse-debug/scripts/tests/fixture.test.sh`:

```bash
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
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bash skills/clickhouse-debug/scripts/tests/fixture.test.sh`
Expected: FAIL — `_fixture.sh` does not exist yet (source error / function not found).

- [ ] **Step 4: Implement `_fixture.sh`**

Create `skills/clickhouse-debug/scripts/_fixture.sh`:

```bash
#!/usr/bin/env bash
# Shared fixture capture/replay for chq.sh and promq.sh (eval harness support).
# Source this. With neither CH_CAPTURE_DIR nor CH_REPLAY_DIR set, it is inert.

# Collapse whitespace runs and trim, so cosmetic formatting never changes a key.
_fixture_norm() { printf '%s' "$1" | tr '\n\t' '  ' | tr -s ' ' | sed 's/^ *//; s/ *$//'; }

# Portable sha1 of stdin -> bare hex digest.
_fixture_sha1() {
  if command -v sha1sum >/dev/null 2>&1; then sha1sum | cut -d' ' -f1
  else shasum -a 1 | cut -d' ' -f1; fi
}

# Stable key for (script, logical-input). Script name keeps keyspaces disjoint.
_fixture_key() { printf '%s|%s' "$1" "$(_fixture_norm "$2")" | _fixture_sha1; }

# Replay: print fixture + return 0 on hit; return 2 on miss; return 1 if inactive.
fixture_replay() {
  [ -n "${CH_REPLAY_DIR:-}" ] || return 1
  local file; file="$CH_REPLAY_DIR/$(_fixture_key "$1" "$2").tsv"
  if [ -f "$file" ]; then cat "$file"; return 0; fi
  echo "no fixture for: $2" >&2
  return 2
}

# Capture: record output + log mapping. No-op if CH_CAPTURE_DIR unset.
fixture_capture() {
  [ -n "${CH_CAPTURE_DIR:-}" ] || return 0
  mkdir -p "$CH_CAPTURE_DIR"
  local key; key="$(_fixture_key "$1" "$2")"
  printf '%s' "$3" > "$CH_CAPTURE_DIR/$key.tsv"
  printf '%s\t%s\n' "$key" "$(_fixture_norm "$2")" >> "$CH_CAPTURE_DIR/index.tsv"
}
```

- [ ] **Step 5: Write the test runner**

Create `skills/clickhouse-debug/scripts/tests/run.sh`:

```bash
#!/usr/bin/env bash
# Run every *.test.sh in this dir; non-zero exit if any fails.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fails=0
for t in "$HERE"/*.test.sh; do
  echo "== $(basename "$t") =="
  bash "$t" || fails=1
done
exit "$fails"
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `bash skills/clickhouse-debug/scripts/tests/fixture.test.sh`
Expected: `PASS: fixture.test.sh`

- [ ] **Step 7: Commit**

```bash
git add skills/clickhouse-debug/scripts/_fixture.sh skills/clickhouse-debug/scripts/tests/
git commit -m "feat: add fixture capture/replay helper for eval harness"
```

---

## Task 3: Wire capture/replay into `chq.sh`

**Files:**
- Modify: `skills/clickhouse-debug/scripts/chq.sh` (move `CH_URL` requirement; add source+replay+capture)
- Create: `skills/clickhouse-debug/scripts/tests/chq-replay.test.sh`

**Interfaces:**
- Consumes: `fixture_replay`/`fixture_capture` from `_fixture.sh` (Task 2).
- Produces: `chq.sh` honoring `CH_REPLAY_DIR` (short-circuit before any network, no `CH_URL`/creds needed) and `CH_CAPTURE_DIR` (record successful real responses). Replay miss → exit `3`.

- [ ] **Step 1: Write the failing test**

Create `skills/clickhouse-debug/scripts/tests/chq-replay.test.sh`:

```bash
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash skills/clickhouse-debug/scripts/tests/chq-replay.test.sh`
Expected: FAIL — replay isn't wired; `chq.sh` currently requires `CH_URL` (exits before any replay) and never captures.

- [ ] **Step 3: Move the `CH_URL` requirement below the replay block**

In `chq.sh`, delete the early requirement at line 51:

```bash
CH_URL="${CH_URL:?set CH_URL, e.g. export CH_URL=http://node:8123}"
```

Leave `CH_USER`/`CH_PASS` defaults at lines 52–53 as they are (they have safe `:-` defaults, so they don't abort).

- [ ] **Step 4: Insert the source + replay block after the SQL is resolved**

Immediately after the line `: "${sql:?provide SQL as arg, via -f FILE, or on stdin}"` (line 79), insert:

```bash
# --- eval harness hook: replay short-circuits before any network/credentials ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_fixture.sh
. "$SCRIPT_DIR/_fixture.sh"
if [ -n "${CH_REPLAY_DIR:-}" ]; then
  if fixture_replay chq "$sql"; then exit 0; fi
  echo "chq.sh: replay miss (CH_REPLAY_DIR=$CH_REPLAY_DIR) — capture this probe or fix the scenario." >&2
  exit 3
fi
# Real run needs the endpoint; require it here (after replay opted out).
CH_URL="${CH_URL:?set CH_URL, e.g. export CH_URL=http://node:8123}"
```

- [ ] **Step 5: Insert the capture call before the final `exit`**

Immediately before the final `exit "$rc"` (currently line 152), insert:

```bash
# --- eval harness hook: record successful real responses as fixtures ---
if [ "$rc" -eq 0 ] && [ -n "$resp" ]; then
  fixture_capture chq "$sql" "$resp"
fi
```

- [ ] **Step 6: Add a one-line note to the header comment**

After the existing `# export CH_READONLY=1 ...` block (around line 24), add:

```bash
#   # Eval harness only (ignored in normal use):
#   #   CH_REPLAY_DIR=dir  -> return canned fixture for this query, no network
#   #   CH_CAPTURE_DIR=dir -> record this query's real response as a fixture
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `bash skills/clickhouse-debug/scripts/tests/chq-replay.test.sh`
Expected: `PASS: chq-replay.test.sh`

- [ ] **Step 8: Verify no behavior change when idle**

Run: `bash -n skills/clickhouse-debug/scripts/chq.sh && echo "syntax-ok"`
Expected: `syntax-ok` (and the replay/capture blocks are inert with neither env var set — confirmed by the unchanged retry/cap logic below them).

- [ ] **Step 9: Commit**

```bash
git add skills/clickhouse-debug/scripts/chq.sh skills/clickhouse-debug/scripts/tests/chq-replay.test.sh
git commit -m "feat: add capture/replay modes to chq.sh"
```

---

## Task 4: Wire capture/replay into `promq.sh`

**Files:**
- Modify: `skills/clickhouse-debug/scripts/promq.sh` (move `PROM` requirement; hoist span/step defaults; add source+replay+capture around formatted output)
- Create: `skills/clickhouse-debug/scripts/tests/promq-replay.test.sh`

**Interfaces:**
- Consumes: `fixture_replay`/`fixture_capture` (Task 2).
- Produces: `promq.sh` keyed on the **logical** invocation `promq|<q>|<mode>|<span>|<step>` (NOT the resolved epoch `start`/`end`, which vary per run). Replay needs no `PROM`. Capture records the formatted table the agent sees. Replay miss → exit `3`.

- [ ] **Step 1: Write the failing test**

Create `skills/clickhouse-debug/scripts/tests/promq-replay.test.sh`:

```bash
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash skills/clickhouse-debug/scripts/tests/promq-replay.test.sh`
Expected: FAIL — replay not wired; `promq.sh` requires `PROM` first and exits.

- [ ] **Step 3: Hoist span/step defaults and remove the in-branch re-default**

In `promq.sh`, change the parse block (lines 26–27) from:

```bash
q="${1:?usage: promq.sh 'PROMQL' [range SPAN STEP]}"
mode="${2:-instant}"
```

to:

```bash
q="${1:?usage: promq.sh 'PROMQL' [range SPAN STEP]}"
mode="${2:-instant}"
span="${3:-1h}"; step="${4:-60s}"   # effective values; also used for the fixture key
```

Then in the range branch (line 31), delete the now-duplicate:

```bash
  span="${3:-1h}"; step="${4:-60s}"
```

(Leave the rest of the range branch — `num`, `unit`, `start`, `end` — unchanged.)

- [ ] **Step 4: Move the `PROM` requirement below a new replay block**

Delete the early `PROM` check (lines 20–24):

```bash
PROM="${PROM:-}"
if [ -z "$PROM" ]; then
  echo "ERROR: set the Prometheus base URL first, e.g. export PROM='https://prometheus.example.com'" >&2
  exit 2
fi
```

Immediately AFTER the `span`/`step` line from Step 3, insert:

```bash
# --- eval harness hook: replay short-circuits before any network/PROM needed ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_fixture.sh
. "$SCRIPT_DIR/_fixture.sh"
_logical="$q|$mode|$([ "$mode" = range ] && printf '%s|%s' "$span" "$step" || printf '|')"
if [ -n "${CH_REPLAY_DIR:-}" ]; then
  if fixture_replay promq "$_logical"; then exit 0; fi
  echo "promq.sh: replay miss (CH_REPLAY_DIR=$CH_REPLAY_DIR) — capture this probe or fix the scenario." >&2
  exit 3
fi
PROM="${PROM:-}"
if [ -z "$PROM" ]; then
  echo "ERROR: set the Prometheus base URL first, e.g. export PROM='https://prometheus.example.com'" >&2
  exit 2
fi
```

Note: in instant mode `_logical` becomes `up|instant|` — matching the test's `up|instant||` key? The test uses `"up|instant||"`. Make the instant branch emit two trailing bars for parity. Replace the `_logical=` line with:

```bash
if [ "$mode" = range ]; then _logical="$q|$mode|$span|$step"; else _logical="$q|$mode||"; fi
```

(Use this form; it is unambiguous and matches the test keys `up|instant||` and `node_mem|range|1h|60s`.)

- [ ] **Step 5: Capture the formatted output**

The script currently pipes the final formatting straight to stdout (lines 77–88). Refactor so the formatted text is captured into a variable, printed, then recorded. Replace the whole final `if [ "$mode" = "range" ]; then … else … fi` block (lines 77–88) with:

```bash
if [ "$mode" = "range" ]; then
  out="$(printf '%s' "$raw" \
  | jq -r '.data.result[] | . as $s
      | ([.values[][1]|tonumber] | (add/length) as $avg | (max) as $mx
         | "\($avg)\t\($mx)")
      as $stats | "\($stats)\t\($s.metric|to_entries|map("\(.key)=\(.value)")|join(","))"' \
  | sort -rn -k2 | awk -F'\t' 'BEGIN{printf "%-12s %-12s %s\n","AVG","MAX","SERIES"}{printf "%-12.4f %-12.4f %s\n",$1,$2,$3}')"
else
  out="$(printf '%s' "$raw" \
  | jq -r '.data.result[] | "\(.value[1])\t\(.metric|to_entries|map("\(.key)=\(.value)")|join(","))"' \
  | sort -rn | awk -F'\t' 'BEGIN{printf "%-14s %s\n","VALUE","SERIES"}{printf "%-14.4f %s\n",$1,$2}')"
fi
printf '%s\n' "$out"
fixture_capture promq "$_logical" "$out"
```

- [ ] **Step 6: Add a one-line note to the header comment**

After the existing Notes block (around line 16), add:

```bash
#   - Eval harness only (ignored in normal use): CH_REPLAY_DIR=dir returns a
#     canned fixture for this query; CH_CAPTURE_DIR=dir records the formatted
#     output as a fixture. Keyed on q|mode|span|step (not the resolved epochs).
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `bash skills/clickhouse-debug/scripts/tests/promq-replay.test.sh`
Expected: `PASS: promq-replay.test.sh`

- [ ] **Step 8: Run the whole script-test suite + syntax check**

Run: `bash skills/clickhouse-debug/scripts/tests/run.sh && bash -n skills/clickhouse-debug/scripts/promq.sh && echo ok`
Expected: all `PASS:` lines, then `ok`.

- [ ] **Step 9: Commit**

```bash
git add skills/clickhouse-debug/scripts/promq.sh skills/clickhouse-debug/scripts/tests/promq-replay.test.sh
git commit -m "feat: add capture/replay modes to promq.sh"
```

---

## Task 5: Judge prompt + `judge.sh`

**Files:**
- Create: `evals/judge-prompt.md`
- Create: `evals/judge.sh`
- Create: `evals/tests/harness.test.sh` (judge portion; run.sh portion added in Task 6)

**Interfaces:**
- Produces: `judge.sh <scenario-dir> <transcript-file>` — concatenates `judge-prompt.md` + the scenario's `rubric.md` + the transcript, pipes to `${EVAL_JUDGE_CMD:-claude -p}` on stdin, prints the model's scorecard to stdout. Missing args → exit `2`. Missing rubric/transcript → exit `2` with a clear message.

- [ ] **Step 1: Write the judge prompt**

Create `evals/judge-prompt.md`:

```markdown
You are grading a ClickHouse incident diagnosis produced by the clickhouse-debug
skill. You are given (1) a RUBRIC of pass criteria and (2) the TRANSCRIPT of the
diagnosis. Judge ONLY what the transcript actually says — do not give credit for
what a good answer "would" say.

For each numbered rubric criterion output one row:

| # | Criterion | Verdict | Evidence (quote from transcript) |

Verdict is PASS or FAIL. Quote the exact transcript text that justifies it; if
you cannot find justifying text, the verdict is FAIL.

After the table, output one line:

OVERALL: PASS  — only if every criterion marked "critical" in the rubric is PASS.
OVERALL: FAIL  — otherwise. Then list the failing critical criteria by number.
```

- [ ] **Step 2: Write the failing test (judge portion)**

Create `evals/tests/harness.test.sh`:

```bash
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

finish "harness.test.sh"
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bash evals/tests/harness.test.sh`
Expected: FAIL — `judge.sh` does not exist.

- [ ] **Step 4: Implement `judge.sh`**

Create `evals/judge.sh`:

```bash
#!/usr/bin/env bash
# Score a diagnosis transcript against a scenario rubric using an LLM judge.
# Usage: judge.sh <scenario-dir> <transcript-file>
# Judge command is injectable for testing: EVAL_JUDGE_CMD (default: claude -p).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

scn="${1:-}"; transcript="${2:-}"
if [ -z "$scn" ] || [ -z "$transcript" ]; then
  echo "usage: judge.sh <scenario-dir> <transcript-file>" >&2; exit 2
fi
[ -f "$scn/rubric.md" ] || { echo "judge.sh: no rubric at $scn/rubric.md" >&2; exit 2; }
[ -f "$transcript" ]    || { echo "judge.sh: no transcript at $transcript" >&2; exit 2; }

payload="$(
  cat "$HERE/judge-prompt.md"
  printf '\n\n===== RUBRIC =====\n\n'; cat "$scn/rubric.md"
  printf '\n\n===== TRANSCRIPT =====\n\n'; cat "$transcript"
)"

printf '%s' "$payload" | ${EVAL_JUDGE_CMD:-claude -p}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash evals/tests/harness.test.sh`
Expected: `PASS: harness.test.sh`

- [ ] **Step 6: Commit**

```bash
git add evals/judge-prompt.md evals/judge.sh evals/tests/harness.test.sh
git commit -m "feat: add eval judge (rubric scorer) with stubbable judge command"
```

---

## Task 6: Scenario runner `run.sh`

**Files:**
- Create: `evals/run.sh`
- Modify: `evals/tests/harness.test.sh` (append run.sh cases)

**Interfaces:**
- Consumes: a scenario dir containing `prompt.md`, `fixtures/`, `meta.yaml`.
- Produces: `run.sh <scenario-dir> [transcript-out]` — exports `CH_REPLAY_DIR=<scenario>/fixtures`, builds a prompt (harness preamble + `prompt.md`), runs `${EVAL_AGENT_CMD:-claude -p}` with the prompt on stdin, writes stdout to the transcript (default `<scenario>/last-transcript.txt`), and echoes the transcript path. If `CH_SRC` is set, warns when `git -C "$CH_SRC" describe` doesn't match `meta.yaml`'s `version`. Missing scenario → exit `2`.

- [ ] **Step 1: Append failing run.sh cases to `evals/tests/harness.test.sh`**

Insert BEFORE the final `finish "harness.test.sh"` line:

```bash
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash evals/tests/harness.test.sh`
Expected: FAIL — `run.sh` does not exist.

- [ ] **Step 3: Implement `run.sh`**

Create `evals/run.sh`:

```bash
#!/usr/bin/env bash
# Drive a subagent through one scenario in replay mode and save its transcript.
# Usage: run.sh <scenario-dir> [transcript-out]
# Agent command is injectable for testing: EVAL_AGENT_CMD (default: claude -p).
set -euo pipefail

scn="${1:-}"
if [ -z "$scn" ] || [ ! -d "$scn" ]; then
  echo "usage: run.sh <scenario-dir> [transcript-out]   (scenario dir not found)" >&2
  exit 2
fi
[ -f "$scn/prompt.md" ] || { echo "run.sh: no prompt.md in $scn" >&2; exit 2; }
out="${2:-$scn/last-transcript.txt}"

# Optional source-version sanity check (the skill confirms against matched source).
if [ -n "${CH_SRC:-}" ] && [ -f "$scn/meta.yaml" ]; then
  want="$(sed -n 's/^version:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "$scn/meta.yaml")"
  have="$(git -C "$CH_SRC" describe --tags 2>/dev/null || echo unknown)"
  case "$have" in *"$want"*) ;; *) echo "run.sh: WARNING CH_SRC at [$have] != scenario version [$want]" >&2;; esac
fi

export CH_REPLAY_DIR="$(cd "$scn/fixtures" && pwd)"

prompt="$(
  cat <<'PREAMBLE'
You are debugging a ClickHouse incident using the clickhouse-debug skill.
The probe scripts (chq.sh / promq.sh) are in REPLAY mode: they return canned
fixtures and never touch a network, so run them exactly as the skill instructs.
A replay miss (exit 3, "no fixture for: ...") means you tried a probe the
scenario did not capture — note it and continue with what you can confirm.
Produce a full root-cause writeup in the skill's RCA format.

--- INCIDENT ---
PREAMBLE
  cat "$scn/prompt.md"
)"

printf '%s' "$prompt" | ${EVAL_AGENT_CMD:-claude -p} | tee "$out"
echo "run.sh: transcript -> $out" >&2
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash evals/tests/harness.test.sh`
Expected: `PASS: harness.test.sh`

- [ ] **Step 5: Commit**

```bash
git add evals/run.sh evals/tests/harness.test.sh
git commit -m "feat: add eval scenario runner with replay wiring and stubbable agent"
```

---

## Task 7: Seed scenario — range-JOIN OOM

**Files:**
- Create: `evals/scenarios/range-join-oom/meta.yaml`
- Create: `evals/scenarios/range-join-oom/prompt.md`
- Create: `evals/scenarios/range-join-oom/rubric.md`
- Create: `evals/scenarios/range-join-oom/fixtures/*.tsv` + `index.tsv`

**Interfaces:**
- Consumes: `run.sh`/`judge.sh` (Tasks 5–6); the capture/replay scripts (Tasks 3–4).
- Produces: a scenario that goes OVERALL PASS for a correct diagnosis and OVERALL FAIL when the skill's range-JOIN guidance is removed — the Phase-1 discrimination proof.

This task authors content, then **converges fixtures empirically** (run → fill misses → repeat). That loop is the method, not a placeholder: the exact-match keying means we cannot pre-know every query the agent emits, so we seed the obvious probes and add the rest from the miss messages.

- [ ] **Step 1: Write `meta.yaml`**

```yaml
version: "25.8.11.66-lts"
deployment: bare-metal
domain: memory-oom
summary: an ad-hoc range-JOIN on asynchronous_metric_log OOM-killed a node
```

- [ ] **Step 2: Write `prompt.md`**

```markdown
On 2026-06-20 around 14:32 UTC, bare-metal node `ch-07` was OOM-killed by the
kernel and restarted on its own. Prometheus and a read-only HTTP user are
configured; the source tree is checked out at the cluster's version. A teammate
was running ad-hoc diagnostic SQL from a laptop around that time. There was no
deploy and no config change in the window.

What is the root cause, and how do we keep a debug query from doing this again?
```

- [ ] **Step 3: Write `rubric.md`**

```markdown
Criteria (critical ones gate OVERALL PASS):

1. (critical) Mechanism: identifies an unbounded / range JOIN — a cross product,
   specifically against a high-volume *_log table (asynchronous_metric_log) — as
   the memory blow-up. NOT merely "a heavy query" or "high memory usage".
2. (critical) Evidence: cites the offending query_log row (its memory_usage and
   the JOIN on asynchronous_metric_log) AND correlates it to MemAvailable
   collapsing to ~0 at the 14:3x kill time.
3. (critical) Source: cites at least one matched-source file:line for the
   mechanism (e.g. the join / hash-table memory path, or the OOM/abort path).
4. (critical) Ruled out: names at least one alternative eliminated with its
   signal (e.g. merges/parts backlog, replication, a config/deploy change).
5. No anchoring: does NOT treat any fixture number (a row count, a byte figure)
   as a configured threshold.
6. Ground truth: any rate/size claim is taken from the actual query_log row, not
   inferred from a Prometheus gauge alone.
7. Read-only fix: proposes only read-only / config / query-shape remedies (e.g.
   per-query max_memory_usage cap, avoid range-JOIN); no destructive step shown
   as executed.
```

- [ ] **Step 4: Seed the obvious fixtures**

Compute keys and write fixtures. For each, the key is `_fixture_key <script> <logical-input>`; source the helper to compute them:

```bash
cd skills/clickhouse-debug/scripts && . ./_fixture.sh
FX=../../../evals/scenarios/range-join-oom/fixtures; mkdir -p "$FX"
: > "$FX/index.tsv"

write() {  # script logical-input  (body on stdin)
  k="$(_fixture_key "$1" "$2")"; cat > "$FX/$k.tsv"
  printf '%s\t%s\n' "$k" "$(_fixture_norm "$2")" >> "$FX/index.tsv"
}

# MemAvailable collapse on ch-07 over the incident hour.
write promq 'node_memory_MemAvailable_bytes{instance="ch-07"}|range|1h|60s' <<'EOF'
AVG          MAX          SERIES
2050000000.0000 33000000000.0000 instance=ch-07
EOF

# Node up flips (restart) — value 1 now, but a restart counter is the real tell.
write promq 'up{instance="ch-07"}|instant||' <<'EOF'
VALUE          SERIES
1.0000         instance=ch-07
EOF

# The offending query: a self/range JOIN on asynchronous_metric_log, huge memory.
write chq 'SELECT event_time, query_id, user, memory_usage, query FROM clusterAllReplicas(default, system.query_log) WHERE event_time BETWEEN '"'"'2026-06-20 14:25:00'"'"' AND '"'"'2026-06-20 14:33:00'"'"' AND type IN ('"'"'QueryFinish'"'"','"'"'ExceptionWhileProcessing'"'"') ORDER BY memory_usage DESC LIMIT 20' <<'EOF'
event_time	query_id	user	memory_usage	query
2026-06-20 14:31:58	a1b2-oom	analyst	61203400000	SELECT count() FROM system.asynchronous_metric_log a JOIN system.asynchronous_metric_log b ON a.event_time >= b.event_time AND a.event_time <= b.event_time + 60
EOF
```

(These three are representative; the bodies are synthetic TSV the scripts would emit. Adjust column shapes only if the skill's reference queries differ.)

- [ ] **Step 5: Smoke-test the runner plumbing with a stub agent**

Run (proves wiring without spending a model):

```bash
EVAL_AGENT_CMD='cat' bash evals/run.sh evals/scenarios/range-join-oom /tmp/rjo.txt
grep -q "Investigate\|root cause\|INCIDENT" /tmp/rjo.txt && echo "plumbing-ok"
```

Expected: `plumbing-ok` and `/tmp/rjo.txt` contains the preamble + prompt.

- [ ] **Step 6: Converge fixtures with a real agent run**

```bash
EVAL_AGENT_CMD='claude -p' bash evals/run.sh evals/scenarios/range-join-oom /tmp/rjo.txt
```

For every `no fixture for: <query>` printed to stderr, author a matching fixture
(use the `write` helper from Step 4 with the exact logical input) with a realistic
body, then re-run. Repeat until the agent completes a full RCA with no blocking
miss. Commit the fixtures as you add them.

- [ ] **Step 7: Verify the scenario PASSES**

```bash
bash evals/judge.sh evals/scenarios/range-join-oom /tmp/rjo.txt
```

Expected: a scorecard table with criteria 1–4 PASS and `OVERALL: PASS`.

- [ ] **Step 8: Verify the harness DISCRIMINATES (negative control)**

Temporarily neutralize the skill's range-JOIN guidance to confirm the scenario
can fail:

```bash
cp skills/clickhouse-debug/SKILL.md /tmp/SKILL.bak
# Remove the "Never range-JOIN" resource-safety bullet for this check only:
sed -i.bak '/Never range-JOIN/d' skills/clickhouse-debug/SKILL.md
EVAL_AGENT_CMD='claude -p' bash evals/run.sh evals/scenarios/range-join-oom /tmp/rjo-neg.txt
bash evals/judge.sh evals/scenarios/range-join-oom /tmp/rjo-neg.txt   # expect OVERALL: FAIL (often)
cp /tmp/SKILL.bak skills/clickhouse-debug/SKILL.md   # RESTORE
git checkout skills/clickhouse-debug/SKILL.md         # ensure clean
```

Expected: the neutralized run is meaningfully more likely to miss criterion 1/3
(OVERALL: FAIL). Record the observed before/after verdicts in the commit message.
(If both pass, the scenario isn't discriminating — strengthen the rubric/fixtures
before considering Phase 1 done.)

- [ ] **Step 9: Commit**

```bash
git add evals/scenarios/range-join-oom
git commit -m "feat: add range-JOIN-OOM seed eval scenario (proves harness discriminates)"
```

---

## Task 8: Document the harness + release 0.5.0

**Files:**
- Modify: `README.md` (add an "Evals" section after "Bundled helpers")
- Modify: `CONTRIBUTING.md` (sanitization checklist + adding a scenario)
- Modify: `CHANGELOG.md` (0.5.0 entry)
- Modify (via script): SKILL.md frontmatter, metadata.json, plugin.json, marketplace.json ×2

**Interfaces:**
- Consumes: everything from Tasks 1–7.
- Produces: a releasable 0.5.0 with the harness documented for maintainers.

- [ ] **Step 1: Add the README "Evals" section**

Insert after the "### Bundled helpers" subsection in `README.md`:

```markdown
### Evals (maintainers)

A fixture-replay harness lets you measure the skill without a live cluster.
`chq.sh`/`promq.sh` gain two env-gated modes: `CH_CAPTURE_DIR` records a probe's
real output as a fixture; `CH_REPLAY_DIR` returns that fixture instead of hitting
the network. Scenarios live in `evals/scenarios/<slug>/` (`prompt.md`,
`fixtures/`, `rubric.md`, `meta.yaml`). Run one and score it:

    EVAL_AGENT_CMD='claude -p' ./evals/run.sh evals/scenarios/range-join-oom out.txt
    ./evals/judge.sh evals/scenarios/range-join-oom out.txt

Committed fixtures are synthetic/sanitized; raw captures stay in the ignored
`evals/local/`. See CONTRIBUTING.md for the sanitization checklist.
```

- [ ] **Step 2: Add the CONTRIBUTING checklist**

Append to `CONTRIBUTING.md`:

```markdown
## Adding an eval scenario

1. Create `evals/scenarios/<slug>/` with `meta.yaml` (version, deployment,
   domain, summary), `prompt.md` (the incident as a user reports it), and
   `rubric.md` (numbered criteria; mark the gating ones `(critical)`).
2. Capture fixtures against a real cluster into `evals/local/` with
   `CH_CAPTURE_DIR=evals/local/<slug> ./chq.sh "..."`, then **sanitize** before
   moving them under the scenario's `fixtures/`.
3. Run `./evals/run.sh` and `./evals/judge.sh` until the scenario passes for a
   correct diagnosis and fails for a broken one.

### Fixture sanitization checklist (REQUIRED before committing fixtures)
- [ ] No real hostnames / pod names — replace with `ch-01`, `ch-02`, …
- [ ] No IPs, FQDNs, or internal URLs.
- [ ] No tenant / customer / database / user identifiers that are real.
- [ ] No real data values in result rows — keep only the shape and magnitudes
      the diagnosis needs.
- [ ] Numbers are plausible but synthetic (don't paste a real production figure
      verbatim if it's sensitive).
```

- [ ] **Step 3: Add the CHANGELOG entry**

Under `## [Unreleased]` replace the placeholder with a new released block:

```markdown
## [0.5.0] - 2026-06-24

Add a fixture-replay eval harness so skill changes become measurable and
regression-safe (Phase 1 of the improvements roadmap; see
docs/superpowers/specs/2026-06-24-clickhouse-debug-improvements-design.md).

### Added
- **Capture/replay in the probe scripts** — `CH_CAPTURE_DIR` records a probe's
  output as a fixture; `CH_REPLAY_DIR` returns the fixture with no network. Both
  are inert when unset, so normal debugging is unchanged. Shared logic in
  `scripts/_fixture.sh`; portable sha1 keying on the normalized query.
- **Eval harness** — `evals/run.sh` (scenario → subagent in replay mode →
  transcript) and `evals/judge.sh` (transcript → rubric scorecard), with the
  agent/judge command injectable (`EVAL_AGENT_CMD`/`EVAL_JUDGE_CMD`) for testing.
- **Seed scenario** `range-join-oom`, proven to pass a correct diagnosis and
  fail a neutered one.
- **Shell unit tests** under `scripts/tests/` and `evals/tests/` (no external
  framework).

### Changed
- `.gitignore` now tracks the harness + sanitized fixtures while keeping raw
  captures in the ignored `evals/local/`.
```

- [ ] **Step 4: Bump the version in all 5 places**

Run: `./scripts/bump-version.sh 0.5.0`
Then verify: `grep -rn "0\.5\.0" skills/clickhouse-debug/SKILL.md skills/clickhouse-debug/metadata.json .claude-plugin/plugin.json .claude-plugin/marketplace.json`
Expected: the version appears in all five locations.

- [ ] **Step 5: Run the full test suite one last time**

Run:
```bash
bash skills/clickhouse-debug/scripts/tests/run.sh && bash evals/tests/harness.test.sh && bash evals/tests/gitignore.test.sh
```
Expected: all `PASS:` lines, overall exit 0.

- [ ] **Step 6: Commit**

```bash
git add README.md CONTRIBUTING.md CHANGELOG.md skills/clickhouse-debug/SKILL.md skills/clickhouse-debug/metadata.json .claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "docs: document eval harness; release v0.5.0"
```

---

## Phase 1 acceptance

- [ ] `bash skills/clickhouse-debug/scripts/tests/run.sh` — all green.
- [ ] `bash evals/tests/harness.test.sh && bash evals/tests/gitignore.test.sh` — all green.
- [ ] `chq.sh`/`promq.sh` unchanged in behavior with neither env var set.
- [ ] `range-join-oom` scores OVERALL PASS for a correct diagnosis and OVERALL FAIL for the neutered-skill control.
- [ ] No real telemetry committed (`git grep` for the synthetic host scheme only).
- [ ] Version is 0.5.0 in all 5 places; CHANGELOG updated.

---

# Follow-up phases (slice-level — each becomes its own plan)

These are **not** detailed to bite-sized steps here. Each is a vertical slice
that, when started, gets its own `docs/superpowers/plans/` document built from
this same TDD shape. Every slice MUST satisfy the slice template from the spec
(§4): the change + source-confirmation (`file:line`, version stamped) + ≥1 eval
scenario that fails-before/passes-after + SKILL.md integration (routing row,
reference entry, `description` keywords, source-map additions) + CHANGELOG/version
bump.

## Phase 2 — coverage slices (one plan each)

For each: a new `references/<name>.md` playbook + a new `evals/scenarios/<slug>/`
that exercises it. Order: distributed → storage → ingest → backup.

1. **`references/distributed-state.md`** — Distributed-engine fan-out: `system.clusters`,
   per-shard `query_log` via `clusterAllReplicas`+`hostName()`, `is_initial_query`/
   `initial_query_id`, hedged requests / `prefer_localhost_replica`, remote-leg
   `SOCKET_TIMEOUT`/`ALL_CONNECTION_TRIES_FAILED`. Scenario: a Distributed SELECT
   hanging on one slow shard.
2. **`references/storage-state.md`** — S3/object storage & tiering: `system.disks`,
   `system.storage_policies`, `part_log` move events, S3 `ProfileEvents`
   (throttling/retries), zero-copy lock contention. Scenario: cold-storage read
   stall / S3 throttling.
3. **`references/ingest-pipeline-state.md`** — async inserts & MV cascades:
   `asynchronous_insert_log`, MV dependency mapping, MV push failure surfacing on
   the insert. Scenario: a blocking MV chain stalling inserts. Fix routes to
   `insert-*` best-practice rules.
4. **`references/backup-state.md`** — BACKUP/RESTORE: `system.backups`,
   restore-in-progress load impact. Scenario: a stuck backup.

## Phase 3 — ergonomics slices (one plan each)

1. **`scripts/bootstrap.sh`** — setup + topology discovery (cluster name, node
   count, per-node version/uptime, version-vs-source check against
   `cmake/autogenerated_versions.txt`, Prometheus label-scheme probe); writes
   `.chenv`. Read-only, capped, fails soft. Unit-tested with stubbed `chq`/`promq`.
2. **`scripts/triage.sh`** — one-pass cheap-signal-first snapshot (Prometheus
   up/MemAvailable/OOM/restarts + capped `chq` errors/parts/merges/replicas),
   honoring `clusterAllReplicas` when proxy-fronted. Unit-tested via replay.
3. **Token/context-cost cut** — trim `SKILL.md` to a lean spine; split any
   oversized reference into symptom-scoped sub-files. **Guardrail:** all Phase
   1–2 eval scenarios stay green; report measured before/after context size.
   (Sequenced last precisely so the harness can prove no capability was lost.)
```
