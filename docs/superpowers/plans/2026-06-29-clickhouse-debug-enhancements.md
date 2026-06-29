# clickhouse-debug v0.6.0 Enhancements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce live-investigation friction and enforce the read-only/capped safety guarantee by adding a `preflight.sh` readiness check, an executable symptom→specialist routing map, model-side companion detection, and a layered curl-guard plugin hook to the `clickhouse-debug` skill.

**Architecture:** Three small portable bash components (`preflight.sh`, `routing.tsv` + `route.sh`, the guard *script*) plus a Claude Code plugin-only *wiring* layer for the hook. Everything reuses existing repo conventions: pure bash, `.chenv` sourcing, `chq.sh`'s caps (preflight calls `chq.sh` rather than its own curl), the shared `_fixture.sh` replay hook, and the `scripts/tests/*.test.sh` harness run by `scripts/tests/run.sh`.

**Tech Stack:** Bash, `curl`, `jq`, ClickHouse HTTP interface, Prometheus HTTP API, Claude Code plugin hooks.

## Global Constraints

- All scripts are pure bash starting with a `set` line: `set -euo pipefail` for query/lookup scripts; `set -uo pipefail` for `preflight.sh` (it must run every check and summarize, so no `-e`).
- Never mutate the cluster. Every cluster read goes through `chq.sh` so the `agent-query-safety` caps apply — no hand-rolled capped curl.
- Scripts live in `skills/clickhouse-debug/scripts/` (and `scripts/hooks/`); references in `skills/clickhouse-debug/references/`; tests in `skills/clickhouse-debug/scripts/tests/` and run by `skills/clickhouse-debug/scripts/tests/run.sh`.
- Honor the eval replay hook: source `_fixture.sh` and short-circuit on `CH_REPLAY_DIR` where the script issues cluster reads (achieved here by delegating reads to `chq.sh`, which already does this).
- ClickHouse compatibility floor: 23.8+ (matches `metadata.json`).
- The version string lives in 5 places; bump only via `./scripts/bump-version.sh X.Y.Z` (never hand-edit). Target version: **0.6.0**.
- Commit messages use conventional-commit format (`feat:`, `test:`, `docs:`, `release:`). Attribution/co-author trailers are disabled globally — do not add them.
- `jq` is a runtime dependency for `promq.sh` and the guard hook; assume it is present (already required by the repo).

---

## File Structure

**Create:**
- `skills/clickhouse-debug/scripts/preflight.sh` — step-0 readiness check.
- `skills/clickhouse-debug/references/routing.tsv` — symptom/error-code → reference + specialist map (single source of truth).
- `skills/clickhouse-debug/scripts/route.sh` — lookup over `routing.tsv`.
- `skills/clickhouse-debug/scripts/hooks/pretooluse-chq-guard.sh` — the curl-guard hook script (travels via npx; wired only by the plugin).
- `skills/clickhouse-debug/scripts/tests/preflight.test.sh`
- `skills/clickhouse-debug/scripts/tests/route.test.sh`
- `skills/clickhouse-debug/scripts/tests/routing.test.sh`
- `skills/clickhouse-debug/scripts/tests/guard.test.sh`
- `hooks/hooks.json` — plugin hook wiring (repo root; plugin-only).

**Modify:**
- `.claude-plugin/plugin.json` — add the `"hooks"` key.
- `skills/clickhouse-debug/SKILL.md` — wire preflight as step 0, strengthen companion-availability check, mention `route.sh`, add the enforcement note. (Version field bumped by tooling in Task 6.)
- `README.md` — bundled helpers, repo-layout tree, plugin-hook note.
- `CHANGELOG.md` — 0.6.0 entry.

---

## Task 1: Executable routing (`routing.tsv` + `route.sh` + drift guard)

**Files:**
- Create: `skills/clickhouse-debug/references/routing.tsv`
- Create: `skills/clickhouse-debug/scripts/route.sh`
- Create: `skills/clickhouse-debug/scripts/tests/route.test.sh`
- Create: `skills/clickhouse-debug/scripts/tests/routing.test.sh`
- Reference (read-only): `skills/clickhouse-debug/SKILL.md` (the routing table at the "Routing into the altinity specialists" section)

**Interfaces:**
- Produces: `route.sh <term>` — prints one line per match: `<pattern>\t-> <primary_reference> + Skill: <specialist>  (<note>)`; on no match prints an `altinity-expert-clickhouse-overview` fallback hint to stderr and exits 0.
- Produces: `references/routing.tsv` — header row `pattern\tprimary_reference\tspecialist\tnote`, then one row per signature. Column 3 (`specialist`) set must equal the set of `altinity-expert-clickhouse-*` tokens appearing in SKILL.md routing-table rows (lines containing `|`).

- [ ] **Step 1: Create `routing.tsv`**

Create `skills/clickhouse-debug/references/routing.tsv` with **tab-separated** columns (ensure real tabs, not spaces):

```
pattern	primary_reference	specialist	note
overview	references/cluster-state.md	altinity-expert-clickhouse-overview	don't know where to start — health snapshot + routing
cache	references/query-state.md	altinity-expert-clickhouse-caches	mark / uncompressed / query cache hit-ratio
dictionary	references/query-state.md	altinity-expert-clickhouse-dictionaries	load failure / high dictionary memory
kafka	references/query-state.md	altinity-expert-clickhouse-kafka	consumer lag / errors / thread starvation
mutation	references/query-state.md	altinity-expert-clickhouse-mutations	stuck or slow ALTER UPDATE/DELETE
ACCESS_DENIED	references/query-state.md	altinity-expert-clickhouse-grants	grants / auth after upgrade
AUTHENTICATION_FAILED	references/query-state.md	altinity-expert-clickhouse-grants	grants / auth after upgrade
NOT_ENOUGH_PRIVILEGES	references/query-state.md	altinity-expert-clickhouse-grants	grants / privileges
index	references/query-state.md	altinity-expert-clickhouse-index-analysis	scans larger than expected / ORDER BY / skip-index
INSERT	references/query-state.md	altinity-expert-clickhouse-ingestion	slow INSERT / high part-creation / batch sizing
SELECT	references/query-state.md	altinity-expert-clickhouse-reporting	slow SELECT latency / query-pattern analysis
schema	references/query-state.md	altinity-expert-clickhouse-schema	partitioning / ORDER BY / MV anti-patterns
storage	references/cluster-state.md	altinity-expert-clickhouse-storage	disk usage / compression / part sizes / slow IO
TOO_MANY_PARTS	references/query-state.md	altinity-expert-clickhouse-part-log	merge backlog / micro-batch inserts
part_log	references/query-state.md	altinity-expert-clickhouse-part-log	micro-batch / merge backlog / znode growth
KEEPER_EXCEPTION	references/keeper-state.md	altinity-expert-clickhouse-replication	lead with keeper-state.md
read-only	references/keeper-state.md	altinity-expert-clickhouse-replication	replicas read-only / ON CLUSTER DDL hang / post-Keeper-restart
replication	references/keeper-state.md	altinity-expert-clickhouse-replication	replication lag / queue
CANNOT_SCHEDULE_TASK	references/query-state.md	altinity-expert-clickhouse-metrics	thread-pool / admission stampede
MEMORY_LIMIT_EXCEEDED	references/query-state.md	altinity-expert-clickhouse-metrics	memory pressure — lead with query-state.md; metrics for live saturation
metrics	references/cluster-state.md	altinity-expert-clickhouse-metrics	load / connection saturation / queue buildup
logs	references/query-state.md	altinity-expert-clickhouse-logs	system-log TTL / unbounded log growth
security	references/query-state.md	altinity-expert-clickhouse-security	users / grants / exposure audit
```

> The distinct `specialist` values here are exactly the 16 `altinity-expert-clickhouse-*` skills named in the SKILL.md routing table. Task 5 does not add or remove specialists from that table; if it ever does, `routing.tsv` must be updated in lockstep (the guard test in Step 6 enforces this).

- [ ] **Step 2: Verify the file is tab-separated**

Run: `cat -A skills/clickhouse-debug/references/routing.tsv | head -3`
Expected: each column boundary shows as `^I` (a tab), not spaces. If you see spaces, re-create the file with real tabs.

- [ ] **Step 3: Write `route.sh`**

Create `skills/clickhouse-debug/scripts/route.sh`:

```bash
#!/usr/bin/env bash
# Look up which reference playbook + altinity specialist to use for an error code
# or symptom keyword. Reads references/routing.tsv (the single source of truth);
# the SKILL.md routing table is the human view of the same map.
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
    if (index(p, t) > 0 || index(t, p) > 0)
      printf "%s\t-> %s + Skill: %s  (%s)\n", $1, $2, $3, $4
  }' "$TSV")"

if [ -n "$matches" ]; then
  printf '%s\n' "$matches"
else
  echo "route.sh: no routing match for '$term' — start with altinity-expert-clickhouse-overview (health snapshot), then re-route." >&2
fi
```

- [ ] **Step 4: Make `route.sh` executable**

Run: `chmod +x skills/clickhouse-debug/scripts/route.sh`
Expected: no output, exit 0.

- [ ] **Step 5: Write the failing `route.test.sh`**

Create `skills/clickhouse-debug/scripts/tests/route.test.sh`:

```bash
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
```

- [ ] **Step 6: Write the failing `routing.test.sh` (drift guard)**

Create `skills/clickhouse-debug/scripts/tests/routing.test.sh`:

```bash
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
```

- [ ] **Step 7: Run the new tests**

Run: `bash skills/clickhouse-debug/scripts/tests/route.test.sh && bash skills/clickhouse-debug/scripts/tests/routing.test.sh`
Expected: `PASS: route.test.sh` and `PASS: routing.test.sh`. If `routing.test.sh` FAILS, the diff prints the two sets — reconcile `routing.tsv` against the SKILL.md table (do not edit the table yet; it is the existing source). Both should already match given the Step-1 data.

- [ ] **Step 8: Run the full suite to confirm nothing else broke**

Run: `bash skills/clickhouse-debug/scripts/tests/run.sh`
Expected: every `*.test.sh` prints `PASS`; final exit 0.

- [ ] **Step 9: Commit**

```bash
git add skills/clickhouse-debug/references/routing.tsv \
        skills/clickhouse-debug/scripts/route.sh \
        skills/clickhouse-debug/scripts/tests/route.test.sh \
        skills/clickhouse-debug/scripts/tests/routing.test.sh
git commit -m "feat: executable symptom->specialist routing (routing.tsv + route.sh + drift guard)"
```

---

## Task 2: `preflight.sh` readiness check

**Files:**
- Create: `skills/clickhouse-debug/scripts/preflight.sh`
- Create: `skills/clickhouse-debug/scripts/tests/preflight.test.sh`
- Reference (read-only): `skills/clickhouse-debug/scripts/chq.sh`, `skills/clickhouse-debug/scripts/_fixture.sh`

**Interfaces:**
- Consumes: `chq.sh` (sibling) for all cluster reads — `SELECT version()` and topology — so caps + `CH_REPLAY_DIR` are inherited.
- Produces: `preflight.sh` — reads env (`CH_URL`, `PROM`, `CH_USER`, `CH_PASS`), prints `preflight: <check> <PASS|WARN> ...` lines, ends with a single `STATUS: READY` or `STATUS: BLOCKED: <reasons>` line. Exits non-zero (2) only when `CH_URL` is unset; otherwise exits 0.

- [ ] **Step 1: Write the failing `preflight.test.sh`**

Create `skills/clickhouse-debug/scripts/tests/preflight.test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
. "$HERE/../_fixture.sh"
PRE="$HERE/../preflight.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# A fake CH source tree with a known version.
mkdir -p "$tmp/src/cmake"
cat > "$tmp/src/cmake/autogenerated_versions.txt" <<'EOF'
SET(VERSION_REVISION 54487)
SET(VERSION_MAJOR 24)
SET(VERSION_MINOR 3)
SET(VERSION_PATCH 1)
SET(VERSION_STRING 24.3.1.2672)
EOF

# Seed a chq replay fixture for SELECT version() that matches the source version.
mkdir -p "$tmp/fx"
vkey="$(_fixture_key chq "SELECT version()")"
printf 'version()\n24.3.1.2672\n' > "$tmp/fx/$vkey.tsv"

# Stub curl so /ping and Prometheus health "succeed" without a network.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf 'Ok.\n'
STUB
chmod +x "$tmp/bin/curl"

# Run preflight from inside the fake source tree, in replay mode.
out="$(cd "$tmp/src" && PATH="$tmp/bin:$PATH" \
  CH_REPLAY_DIR="$tmp/fx" CH_URL="http://node:8123" PROM="http://prom:9090" \
  bash "$PRE" 2>&1)"; rc=$?

assert_rc "exits 0 when CH_URL is set" 0 "$rc"
assert_contains "reports source version" "$out" "24.3.1.2672"
assert_contains "version match passes" "$out" "version match"
assert_contains "emits a STATUS line" "$out" "STATUS:"

# Missing CH_URL is the one fatal case.
out2="$(cd "$tmp/src" && PATH="$tmp/bin:$PATH" CH_REPLAY_DIR="$tmp/fx" \
  bash "$PRE" 2>&1)"; rc2=$?
assert_rc "exits 2 when CH_URL unset" 2 "$rc2"

finish "preflight.test.sh"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash skills/clickhouse-debug/scripts/tests/preflight.test.sh`
Expected: FAIL (preflight.sh does not exist yet) — assertions report failure and/or a "No such file" error.

- [ ] **Step 3: Write `preflight.sh`**

Create `skills/clickhouse-debug/scripts/preflight.sh`:

```bash
#!/usr/bin/env bash
# Step-0 readiness check for a clickhouse-debug session. Run it FIRST, from inside
# the version-matched ClickHouse source checkout:
#
#   source ./.chenv && ./preflight.sh
#
# It confirms, in one shot, what used to be manual prose: that you're in a CH
# source tree, that the endpoints answer, that the source version matches the live
# server (line numbers depend on this), and roughly how big the fleet is (so
# fan-out caps can be sized). All cluster reads go through chq.sh, so the
# agent-query-safety caps and CH_REPLAY_DIR apply here too.
#
# NOT -e: we want to run every check and summarize, not abort on the first miss.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHQ="$SCRIPT_DIR/chq.sh"

warns=()        # non-fatal: reduced depth
blockers=()     # the agent should fix these before drilling

# --- 1. Source tree + version --------------------------------------------------
src_ver=""
verfile="cmake/autogenerated_versions.txt"
if [ -f "$verfile" ]; then
  src_ver="$(sed -n 's/.*VERSION_STRING \([0-9][0-9.]*\).*/\1/p' "$verfile" | head -n1)"
  echo "preflight: source tree     PASS  v${src_ver:-?}  ($verfile)"
elif src_ver="$(git describe --tags 2>/dev/null)"; then
  echo "preflight: source tree     PASS  $src_ver  (git describe)"
else
  echo "preflight: source tree     WARN  not a CH source tree — source confirmation unavailable"
  warns+=("not in a CH source tree")
fi

# --- 2. Endpoints --------------------------------------------------------------
if [ -n "${CH_URL:-}" ]; then
  if printf '%s' "$(curl -sk -m 5 "$CH_URL/ping" 2>/dev/null)" | grep -q "Ok."; then
    echo "preflight: ClickHouse ping PASS  $CH_URL"
  else
    echo "preflight: ClickHouse ping WARN  $CH_URL did not return 'Ok.'"
    blockers+=("ClickHouse $CH_URL unreachable")
  fi
else
  echo "preflight: ClickHouse ping FAIL  CH_URL is not set"
  blockers+=("CH_URL not set")
fi

if [ -n "${PROM:-}" ]; then
  ph="$(curl -sk -m 5 "$PROM/-/healthy" 2>/dev/null)"
  if [ -z "$ph" ]; then ph="$(curl -sk -m 5 "$PROM/api/v1/query?query=1" 2>/dev/null)"; fi
  if [ -n "$ph" ]; then
    echo "preflight: Prometheus      PASS  $PROM"
  else
    echo "preflight: Prometheus      WARN  $PROM did not answer (outside view limited)"
    warns+=("Prometheus unreachable")
  fi
else
  echo "preflight: Prometheus      WARN  PROM not set (outside view unavailable)"
  warns+=("PROM not set")
fi

# --- 3. Version match (automated) ---------------------------------------------
# Only meaningful if both the source version and a live endpoint are available.
if [ -n "${CH_URL:-}" ] || [ -n "${CH_REPLAY_DIR:-}" ]; then
  live_ver="$("$CHQ" "SELECT version()" 2>/dev/null | tail -n1)"
  norm() { printf '%s' "$1" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' | head -n1; }
  if [ -n "$src_ver" ] && [ -n "$live_ver" ]; then
    if [ "$(norm "$src_ver")" = "$(norm "$live_ver")" ]; then
      echo "preflight: version match   PASS  source $src_ver == live $live_ver"
    else
      echo "preflight: version match   WARN  source $src_ver vs live $live_ver — line numbers may differ"
      warns+=("source/live version mismatch")
    fi
  elif [ -z "$live_ver" ]; then
    echo "preflight: version match   WARN  could not read live version()"
    warns+=("live version unknown")
  fi
fi

# --- 4. Topology (best-effort) -------------------------------------------------
clusters="$("$CHQ" "SELECT cluster, count() AS n FROM system.clusters GROUP BY cluster ORDER BY n DESC" 2>/dev/null | tail -n +2)"
if [ -n "$clusters" ]; then
  summary="$(printf '%s' "$clusters" | awk -F'\t' '{printf "%s(%s) ", $1, $2}')"
  echo "preflight: clusters        $(printf '%s' "$clusters" | wc -l | tr -d ' ') found: $summary"
else
  echo "preflight: clusters        WARN  could not enumerate system.clusters"
  warns+=("topology unknown")
fi

# --- 5. Companion reminder (model-side check) ---------------------------------
echo "preflight: companions      check your available skills for clickhouse-best-practices, altinity-expert-clickhouse-overview, altinity-profiler-clickhouse — and report any missing (it reduces depth)."

# --- Summary -------------------------------------------------------------------
if [ "${#blockers[@]}" -gt 0 ]; then
  echo "STATUS: BLOCKED: $(IFS='; '; echo "${blockers[*]}")"
elif [ "${#warns[@]}" -gt 0 ]; then
  echo "STATUS: READY (with warnings: $(IFS='; '; echo "${warns[*]}"))"
else
  echo "STATUS: READY"
fi

# Exit non-zero ONLY when CH_URL is missing (the one thing that stops every probe).
if [ -z "${CH_URL:-}" ]; then exit 2; fi
exit 0
```

- [ ] **Step 4: Make `preflight.sh` executable**

Run: `chmod +x skills/clickhouse-debug/scripts/preflight.sh`
Expected: no output, exit 0.

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash skills/clickhouse-debug/scripts/tests/preflight.test.sh`
Expected: `PASS: preflight.test.sh`.

> Note on the topology check under replay: in the test, the `system.clusters` query is a replay miss, so `chq.sh` exits 3 and `$clusters` is empty → preflight prints the topology `WARN` and continues (it does not block). This is intended; the test asserts `STATUS:` is present, not `READY`.

- [ ] **Step 6: Run the full suite**

Run: `bash skills/clickhouse-debug/scripts/tests/run.sh`
Expected: all `PASS`; exit 0.

- [ ] **Step 7: Commit**

```bash
git add skills/clickhouse-debug/scripts/preflight.sh \
        skills/clickhouse-debug/scripts/tests/preflight.test.sh
git commit -m "feat: preflight.sh step-0 readiness check (source/version/endpoints/topology)"
```

---

## Task 3: Curl-guard hook script (portable enforcement core)

**Files:**
- Create: `skills/clickhouse-debug/scripts/hooks/pretooluse-chq-guard.sh`
- Create: `skills/clickhouse-debug/scripts/tests/guard.test.sh`

**Interfaces:**
- Produces: `pretooluse-chq-guard.sh` — a Claude Code `PreToolUse` hook for the `Bash` tool. Reads the hook JSON on stdin, extracts `.tool_input.command`. Exits **2** (block, reason on stderr) only when the command runs `curl` to a ClickHouse port (`8123`/`8443`/`9000`/`9440`), carries a query (`query=` or `--data`), and does not mention `chq.sh`. Exits **0** (allow) for everything else, including bare `/ping`, `chq.sh` calls, non-CH curls, and non-curl commands.

- [ ] **Step 1: Write the failing `guard.test.sh`**

Create `skills/clickhouse-debug/scripts/tests/guard.test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
GUARD="$HERE/../hooks/pretooluse-chq-guard.sh"

# Feed a Bash-tool PreToolUse payload; return the guard's exit code.
guard_rc() {  # command-string
  local payload
  payload="$(printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
    "$(printf '%s' "$1" | jq -R -s .)")"
  printf '%s' "$payload" | bash "$GUARD" >/dev/null 2>&1
  echo $?
}

assert_eq "blocks query curl to :8123" 2 \
  "$(guard_rc 'curl -sk http://h:8123/ --data-urlencode "query=SELECT 1"')"
assert_eq "blocks query= curl to :8443" 2 \
  "$(guard_rc 'curl -sk "https://h:8443/?query=SELECT%201"')"
assert_eq "allows bare /ping" 0 \
  "$(guard_rc 'curl -sk http://h:8123/ping')"
assert_eq "allows chq.sh wrapper" 0 \
  "$(guard_rc 'source ./.chenv && ./chq.sh "SELECT 1"')"
assert_eq "ignores non-CH curl with query" 0 \
  "$(guard_rc 'curl -sk "http://api.example.com/x?query=1"')"
assert_eq "ignores plain bash" 0 \
  "$(guard_rc 'ls -la && echo hi')"

finish "guard.test.sh"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash skills/clickhouse-debug/scripts/tests/guard.test.sh`
Expected: FAIL (guard script does not exist) — assertions fail and/or "No such file".

- [ ] **Step 3: Write the guard script**

Create `skills/clickhouse-debug/scripts/hooks/pretooluse-chq-guard.sh`:

```bash
#!/usr/bin/env bash
# Claude Code PreToolUse(Bash) guard for clickhouse-debug.
#
# Blocks ONE precise mistake: a raw `curl` that fires a QUERY at a ClickHouse port
# without going through chq.sh, so the agent-query-safety caps are absent and the
# probe could OOM-kill a node. Everything else is allowed (fail-open):
#   - bare health checks (curl .../ping) carry no query   -> allowed
#   - anything mentioning chq.sh (the capped wrapper)      -> allowed
#   - curl to non-CH hosts/ports                           -> allowed
#   - non-curl commands                                    -> allowed
#
# Block mechanism: exit 2 + reason on stderr (Claude Code feeds stderr back to the
# model so it self-corrects to chq.sh). Reads the hook payload (JSON) on stdin.
set -uo pipefail

input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"

[ -n "$cmd" ] || exit 0                       # unparseable / non-Bash -> allow
case "$cmd" in *chq.sh*) exit 0;; esac        # the capped wrapper -> allow
case "$cmd" in *curl*) ;; *) exit 0;; esac    # not a curl -> allow

case "$cmd" in                                # must target a ClickHouse port
  *:8123*|*:8443*|*:9000*|*:9440*) ;;
  *) exit 0;;
esac

case "$cmd" in                                # must carry a query (not bare /ping)
  *query=*|*--data*) ;;
  *) exit 0;;
esac

echo "clickhouse-debug: blocked a raw curl carrying a query to a ClickHouse port. Route it through scripts/chq.sh so the agent-query-safety caps (max_memory_usage / max_execution_time / max_rows_to_read / ...) apply — an uncapped probe can OOM-kill a node. For a deliberately heavier read, run chq.sh with inline CH_MAX_* overrides." >&2
exit 2
```

- [ ] **Step 4: Make the guard executable**

Run: `chmod +x skills/clickhouse-debug/scripts/hooks/pretooluse-chq-guard.sh`
Expected: no output, exit 0.

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash skills/clickhouse-debug/scripts/tests/guard.test.sh`
Expected: `PASS: guard.test.sh`.

- [ ] **Step 6: Run the full suite**

Run: `bash skills/clickhouse-debug/scripts/tests/run.sh`
Expected: all `PASS`; exit 0.

- [ ] **Step 7: Commit**

```bash
git add skills/clickhouse-debug/scripts/hooks/pretooluse-chq-guard.sh \
        skills/clickhouse-debug/scripts/tests/guard.test.sh
git commit -m "feat: PreToolUse curl-guard hook script (block uncapped CH query curls)"
```

---

## Task 4: Wire the guard into the Claude Code plugin

**Files:**
- Create: `hooks/hooks.json` (repo root)
- Modify: `.claude-plugin/plugin.json`

**Interfaces:**
- Consumes: `skills/clickhouse-debug/scripts/hooks/pretooluse-chq-guard.sh` (from Task 3), referenced via `${CLAUDE_PLUGIN_ROOT}`.
- Produces: a registered `PreToolUse`→`Bash` hook for plugin installs only. (The npx path copies only `skills/clickhouse-debug/`, so `hooks/hooks.json` and the `plugin.json` change do not travel — exactly the intended layering.)

- [ ] **Step 1: Create `hooks/hooks.json`**

Create `hooks/hooks.json` at the repo root:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash",
            "args": ["${CLAUDE_PLUGIN_ROOT}/skills/clickhouse-debug/scripts/hooks/pretooluse-chq-guard.sh"]
          }
        ]
      }
    ]
  }
}
```

- [ ] **Step 2: Validate the JSON**

Run: `jq . hooks/hooks.json`
Expected: the JSON pretty-prints with no parse error.

- [ ] **Step 3: Add the `hooks` key to `plugin.json`**

In `.claude-plugin/plugin.json`, add a `"hooks"` field. Use Edit to change:

```json
  "skills": ["./skills/clickhouse-debug/"]
}
```

to:

```json
  "skills": ["./skills/clickhouse-debug/"],
  "hooks": "./hooks/hooks.json"
}
```

- [ ] **Step 4: Validate `plugin.json`**

Run: `jq . .claude-plugin/plugin.json`
Expected: valid JSON; `.hooks` is `"./hooks/hooks.json"`.

- [ ] **Step 5: Run the full suite (no regressions)**

Run: `bash skills/clickhouse-debug/scripts/tests/run.sh`
Expected: all `PASS`; exit 0.

- [ ] **Step 6: Commit**

```bash
git add hooks/hooks.json .claude-plugin/plugin.json
git commit -m "feat: wire curl-guard PreToolUse hook into the Claude Code plugin"
```

---

## Task 5: Wire the new components into SKILL.md and README

**Files:**
- Modify: `skills/clickhouse-debug/SKILL.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: `preflight.sh`, `route.sh`/`routing.tsv` (Tasks 1–2), the guard + plugin wiring (Tasks 3–4).
- Produces: documentation only. The `routing.test.sh` guard (Task 1) constrains SKILL.md edits — do **not** add/remove `altinity-expert-clickhouse-*` rows from the routing table here without updating `routing.tsv`.

- [ ] **Step 1: Add the preflight step to the "Setup (once per session)" section**

In `skills/clickhouse-debug/SKILL.md`, find this block (near the end of "Setup (once per session)"):

```
- `./promq.sh 'PROMQL'` — instant query, sorted desc.
- `./promq.sh 'PROMQL' range 6h 300s` — range, per-series avg/max.
- `./chq.sh "SELECT ..."` — capped read-only SQL (TSV-with-names).
```

Replace it with:

```
- `./preflight.sh` — **run this first.** Confirms you're in a CH source tree,
  that `CH_URL`/Prometheus answer, that the source version matches the live server
  (the version-match step, automated), and the cluster topology (node count for
  fan-out cap-sizing). Ends with a `STATUS: READY` / `STATUS: BLOCKED:` line. All
  its cluster reads go through `chq.sh`, so the caps apply.
- `./promq.sh 'PROMQL'` — instant query, sorted desc.
- `./promq.sh 'PROMQL' range 6h 300s` — range, per-series avg/max.
- `./chq.sh "SELECT ..."` — capped read-only SQL (TSV-with-names).
- `./route.sh <error-code|keyword>` — which reference + altinity specialist to use
  (executable form of the routing table; backed by `references/routing.tsv`).
```

- [ ] **Step 2: Point input-gathering bullet #5 at preflight**

In the "Before you touch anything: gather inputs" section, replace bullet #5:

```
5. **Source matches the cluster version.** Confirm the checked-out tree is the
   same (or closest) version as the running cluster — `SELECT version()` vs
   `cmake/autogenerated_versions.txt` / `git describe`. If they diverge, say so;
   line numbers and behaviors may differ.
```

with:

```
5. **Source matches the cluster version.** `./preflight.sh` checks this for you
   (source `VERSION_STRING` vs live `SELECT version()`) and prints `PASS` or a
   `WARN: source X vs live Y` — read its output rather than checking by hand. If
   they diverge, say so; line numbers and behaviors may differ.
```

- [ ] **Step 3: Strengthen the companion-availability check (model-side detection)**

In the "Companion skills (install these first)" section, replace the paragraph that begins `**Detecting them:**`:

```
**Detecting them:** check your available skills for `clickhouse-best-practices`,
`altinity-expert-clickhouse-overview`, and `altinity-profiler-clickhouse`. If a
suite is genuinely unavailable and the user can't install it now, proceed but **say
so** — your fixes will be uncited general guidance, and your `system.*` drilling will
be limited to this skill's own references.
```

with:

```
**Detecting them (do this explicitly, up front):** inspect your own available-skills
list for `clickhouse-best-practices`, `altinity-expert-clickhouse-overview`, and
`altinity-profiler-clickhouse`, and **state which are present and which are missing**
before you start drilling. This is the reliable detection path — you already have
your skill list in context, whereas a filesystem scan can't see how each agent
installs skills (`preflight.sh` only prints a reminder to do this check). For any
missing suite, say what depth you lose: no `clickhouse-best-practices` → fixes are
uncited general guidance; no `altinity-expert-clickhouse-*` → `system.*` drilling is
limited to this skill's own references; no `altinity-profiler-clickhouse` → no
pre-built cluster schema map in the Frame stage. Proceed either way, but on the
record.
```

- [ ] **Step 4: Mention `route.sh` in the routing section**

In the "### Routing into the altinity specialists" section, find the opening paragraph that ends with `since the specialists assume an uncapped session.` and append a new sentence to it:

Find:

```
matching `altinity-expert-clickhouse-*` specialist via the Skill tool — then run any
SQL you adopt through `chq.sh` (caps + `clusterAllReplicas`, per the caveat above),
since the specialists assume an uncapped session.
```

Replace with:

```
matching `altinity-expert-clickhouse-*` specialist via the Skill tool — then run any
SQL you adopt through `chq.sh` (caps + `clusterAllReplicas`, per the caveat above),
since the specialists assume an uncapped session. The table below is the human view
of `references/routing.tsv`; run `./route.sh <error-code|keyword>` to look a row up
from any error code the user pastes instead of reciting it.
```

- [ ] **Step 5: Add the enforcement note**

In SKILL.md, immediately after the `### Single node vs. proxy-fronted fleet` subsection (before `## The triage workflow`), add this new subsection:

```
### Enforcement (Claude Code plugin)

When this skill is installed as a **Claude Code plugin**, a `PreToolUse` hook
(`scripts/hooks/pretooluse-chq-guard.sh`) blocks a raw `curl` that fires a query at
a ClickHouse port (8123/8443/9000/9440) without going through `chq.sh` — an uncapped
probe is exactly what once OOM-killed a node. Health checks (`/ping`) and `chq.sh`
itself pass through. Installs via `npx skills add` ship the script but not the wiring
(it lives in the plugin's `hooks/hooks.json`); to enable it there, register the same
`PreToolUse`→`Bash` hook in your own settings pointing at the bundled script.
```

- [ ] **Step 6: Run the drift guard (SKILL.md table must still match routing.tsv)**

Run: `bash skills/clickhouse-debug/scripts/tests/routing.test.sh`
Expected: `PASS: routing.test.sh` (you did not change the table's specialist rows).

- [ ] **Step 7: Update README "Bundled helpers"**

In `README.md`, find the "### Bundled helpers" list and add two bullets after the `promq.sh` bullet:

```
- `scripts/preflight.sh` — step-0 readiness check: source tree + version match (source `VERSION_STRING` vs live `version()`), `CH_URL`/Prometheus reachability, and cluster topology, ending in a `STATUS: READY`/`BLOCKED` line. All cluster reads go through `chq.sh`.
- `scripts/route.sh` — executable symptom→specialist routing over `references/routing.tsv`; `./route.sh CANNOT_SCHEDULE_TASK` prints the reference playbook + altinity specialist to use.
```

- [ ] **Step 8: Note the plugin hook in the README companion/safety area**

In `README.md`, find the "## Safety" section and append this sentence to its paragraph:

Find:

```
Every query this skill issues is read-only and resource-capped, so a probe that would exceed its limits aborts with `MEMORY_LIMIT_EXCEEDED` / `TIMEOUT_EXCEEDED` instead of taking down the node.
```

Replace with:

```
Every query this skill issues is read-only and resource-capped, so a probe that would exceed its limits aborts with `MEMORY_LIMIT_EXCEEDED` / `TIMEOUT_EXCEEDED` instead of taking down the node. Installed as a Claude Code plugin, a `PreToolUse` hook additionally **blocks** a raw uncapped `curl` query to a ClickHouse port, forcing it through the capped `chq.sh` wrapper.
```

- [ ] **Step 9: Update the README repo-layout tree**

In `README.md`, find the repository-layout code block and replace the `skills/clickhouse-debug/` line and add a `hooks/` line so it reads:

Find:

```
├── skills/clickhouse-debug/  # the skill (SKILL.md + metadata.json + references/ + scripts/)
├── LICENSE                   # Apache-2.0
```

Replace with:

```
├── skills/clickhouse-debug/  # the skill (SKILL.md + metadata.json + references/ + scripts/ incl. preflight.sh, route.sh, hooks/)
├── hooks/                    # Claude Code plugin hook wiring (PreToolUse curl-guard)
├── LICENSE                   # Apache-2.0
```

- [ ] **Step 10: Run the full suite**

Run: `bash skills/clickhouse-debug/scripts/tests/run.sh`
Expected: all `PASS`; exit 0.

- [ ] **Step 11: Commit**

```bash
git add skills/clickhouse-debug/SKILL.md README.md
git commit -m "docs: wire preflight, route.sh, companion detection, and the plugin hook into SKILL.md + README"
```

---

## Task 6: Version bump to 0.6.0 + CHANGELOG

**Files:**
- Modify (via tooling): `skills/clickhouse-debug/SKILL.md`, `skills/clickhouse-debug/metadata.json`, `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: all prior tasks (this releases them).
- Produces: synchronized `0.6.0` across the 5 version fields + a changelog entry.

- [ ] **Step 1: Run the bump script**

Run: `./scripts/bump-version.sh 0.6.0`
Expected: prints `Bumped to v0.6.0 (date: ...)` and the changed `version`/`date` lines across `metadata.json`, `plugin.json`, `marketplace.json`, and `SKILL.md`.

- [ ] **Step 2: Verify all five fields moved**

Run: `grep -rn '0.6.0' skills/clickhouse-debug/SKILL.md skills/clickhouse-debug/metadata.json .claude-plugin/plugin.json .claude-plugin/marketplace.json`
Expected: the version appears in SKILL.md frontmatter, `metadata.json`, `plugin.json`, and twice in `marketplace.json` (metadata + entry) — 5 matches total.

- [ ] **Step 3: Add the CHANGELOG entry**

Open `CHANGELOG.md` and add a new top entry under the latest-version convention already used in the file (match its existing heading style). Content:

```
## 0.6.0

### Added
- `scripts/preflight.sh` — step-0 readiness check: source-tree detection, automated
  source-vs-live version match, `CH_URL`/Prometheus reachability, and cluster
  topology, ending in a `STATUS: READY`/`BLOCKED` line. Cluster reads go through
  `chq.sh` (caps + replay inherited).
- Executable routing: `references/routing.tsv` (single source of truth) + `scripts/route.sh`
  to look up the reference playbook + altinity specialist for an error code or keyword,
  guarded by `routing.test.sh` so it can't drift from the SKILL.md table.
- Claude Code plugin `PreToolUse` curl-guard (`scripts/hooks/pretooluse-chq-guard.sh`
  + `hooks/hooks.json`) that blocks a raw uncapped `curl` query to a ClickHouse port,
  forcing it through `chq.sh`. Ships the script via npx; wires it only in the plugin.

### Changed
- SKILL.md: `preflight.sh` is now the documented step 0; the version-match input
  bullet defers to it; companion-availability detection is an explicit model-side
  check; the routing section references `route.sh`.
```

- [ ] **Step 4: Run the full suite (the version bump touched SKILL.md)**

Run: `bash skills/clickhouse-debug/scripts/tests/run.sh`
Expected: all `PASS`; exit 0 (the routing-table specialists are unchanged, so `routing.test.sh` still passes).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "release: v0.6.0"
```

---

## Self-Review

**Spec coverage** (against `docs/superpowers/specs/2026-06-29-clickhouse-debug-enhancements-design.md`):
- `preflight.sh` (friction + automated version-match + topology, calls `chq.sh`, replay-aware, exit-0-with-STATUS) → Task 2. ✓
- `routing.tsv` + `route.sh` + `routing.test.sh` drift guard → Task 1. ✓
- Model-side companion availability detection → Task 5 Step 3 (SKILL.md), reminder line in `preflight.sh` Task 2. ✓
- Curl-guard hook script inside skill dir; wiring in plugin only → Task 3 (script) + Task 4 (wiring). ✓
- SKILL.md + README wiring → Task 5. ✓
- Tests (`routing`, `route`, `preflight`, guard) → Tasks 1–3. ✓
- Version bump 0.6.0 across 5 fields + CHANGELOG → Task 6. ✓
- Deferred items (worked integration examples, new signatures/evals) → correctly absent. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete file content or an exact find/replace; every run step states the expected output. ✓

**Type/name consistency:** `route.sh`, `preflight.sh`, `pretooluse-chq-guard.sh`, `routing.tsv`, `hooks/hooks.json`, the `STATUS:`/`preflight:` line prefixes, the `_fixture_key chq "SELECT version()"` key, and the four test filenames are used identically across tasks. The guard's block contract (exit 2 / allow 0) matches between Task 3 script and its test. The drift guard's `|`-row extraction matches how SKILL.md renders the routing table. ✓

**Risk note carried from spec:** the plugin-hook manifest format (`hooks/hooks.json` + `plugin.json` `"hooks"` key + `${CLAUDE_PLUGIN_ROOT}` + exit-2 block) was verified against current Claude Code plugin docs before writing Tasks 3–4.
