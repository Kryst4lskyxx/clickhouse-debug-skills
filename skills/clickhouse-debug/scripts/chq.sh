#!/usr/bin/env bash
# Run a read-only SQL query against ClickHouse over HTTP, with resource caps
# applied on EVERY query so a debug probe can never OOM-kill or stall a node.
#
# Why HTTP and not clickhouse-client: from a laptop/VPN the native client often
# can't resolve its own hostname or reach the node's native port; HTTP on 8123
# (or 8443 for TLS) is reliable and works with a readonly user.
#
# Configure once per session (export these):
#   export CH_URL='http://chnode.example.com:8123'   # or https://...:8443
#   export CH_USER='readonly_user'
#   export CH_PASS='...'                             # optional
#   # Optional overrides (sane safe defaults below). Raise these DELIBERATELY for
#   # a known-heavy read, ideally inline for one call: CH_MAX_BYTES=... ./chq.sh ...
#   export CH_MAX_MEM=$((20*1024*1024*1024))         # 20 GiB per-query memory cap
#   export CH_MAX_TIME=30                            # wall-clock seconds
#   export CH_MAX_ROWS=$((200*1000*1000))            # max rows to read
#   export CH_MAX_BYTES=$((100*1000*1000*1000))      # max bytes to read (raise for
#                                                   # clusterAllReplicas fan-out)
#   export CH_MAX_EST_TIME=60                        # reject doomed queries upfront
#   export CH_MAX_RESULT_ROWS=100000                 # cap rows returned
#   export CH_MAX_THREADS=4                          # threads per query
#   export CH_READONLY=1                             # ONLY if connecting with a
#                                                   # read-write account (see below)
#   # Eval harness only (ignored in normal use):
#   #   CH_REPLAY_DIR=dir  -> return canned fixture for this query, no network
#   #   CH_CAPTURE_DIR=dir -> record this query's real response as a fixture
#
# Fan-out caution: a `clusterAllReplicas(...)` / `cluster(...)` scan reads from
# EVERY node, so the bytes/rows scanned multiply by the node count. Narrow the
# time window FIRST; only then raise CH_MAX_BYTES for that specific call.
#
# The connecting user SHOULD be a read-only account — that is the real write
# guardrail. If it already is (a readonly=1 or readonly=2 profile), do NOT set
# CH_READONLY: ClickHouse rejects changing the `readonly` setting in readonly
# mode (READONLY / code 164), even to the same value. Set CH_READONLY=1 only
# when you must connect with a read-write user and want client-side protection.
#
# Cap contamination: these caps are sent as query settings, so they show up in
# system.query_log.Settings for every probe this wrapper runs (e.g. max_threads=4,
# max_memory_usage=...). Do NOT read those back as the cluster's production config
# — that's the wrapper's debug cap, not the server default. To read real config,
# query system.settings on a normal session (see references/query-state.md).
#
# Usage:
#   ./chq.sh "SELECT count() FROM system.parts"
#   echo "SELECT ..." | ./chq.sh           # read SQL from stdin
#   ./chq.sh -f query.sql
#
# Output defaults to TabSeparatedWithNames. Append your own FORMAT to override.

set -euo pipefail

CH_USER="${CH_USER:-default}"
CH_PASS="${CH_PASS:-}"

# Safe defaults. These are the single most important guardrail in this skill:
# a debug query that exceeds them aborts with MEMORY_LIMIT_EXCEEDED / TIMEOUT_EXCEEDED
# instead of taking down the node (see the OOM postmortem the skill references).
# These mirror the official `clickhouse-best-practices` rule `agent-query-safety`
# (the canonical source of truth) — keep them in sync with it.
CH_MAX_MEM="${CH_MAX_MEM:-$((20*1024*1024*1024))}"   # 20 GiB  per-query memory
CH_MAX_TIME="${CH_MAX_TIME:-30}"                      # 30 s    wall-clock limit
CH_MAX_ROWS="${CH_MAX_ROWS:-$((1000*1000*1000))}"    # 1e9     rows scanned cap (the real guardrail)
CH_MAX_BYTES="${CH_MAX_BYTES:-$((100*1000*1000*1000))}" # 1e11  bytes scanned cap
CH_MAX_EST_TIME="${CH_MAX_EST_TIME:-60}"             # reject queries projected to exceed this BEFORE they run
CH_MAX_RESULT_ROWS="${CH_MAX_RESULT_ROWS:-100000}"   # cap rows returned
CH_MAX_THREADS="${CH_MAX_THREADS:-4}"                # don't fan out wide

# Resolve the SQL. Order matters: prefer an explicit arg/-f over stdin. We must
# NOT gate on `[ -t 0 ]` — when this runs under an agent/CI Bash tool stdin is
# not a TTY, so that check would wrongly ignore the SQL argument and read an
# empty query from stdin. Only fall back to stdin when no SQL arg was given.
if [ "${1:-}" = "-f" ]; then
  sql="$(cat "${2:?-f needs a file}")"
elif [ "$#" -gt 0 ]; then
  sql="$1"
else
  sql="$(cat)"
fi
: "${sql:?provide SQL as arg, via -f FILE, or on stdin}"

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

auth=(-u "${CH_USER}:${CH_PASS}")

# Resource caps applied to every query — exactly the `agent-query-safety`
# settings. Built as an array so `readonly` can be appended conditionally.
settings=(
  --data-urlencode "max_memory_usage=${CH_MAX_MEM}"
  --data-urlencode "max_execution_time=${CH_MAX_TIME}"
  --data-urlencode "timeout_before_checking_execution_speed=0"
  --data-urlencode "max_estimated_execution_time=${CH_MAX_EST_TIME}"
  --data-urlencode "max_rows_to_read=${CH_MAX_ROWS}"
  --data-urlencode "max_bytes_to_read=${CH_MAX_BYTES}"
  --data-urlencode "max_result_rows=${CH_MAX_RESULT_ROWS}"
  --data-urlencode "result_overflow_mode=break"
  # result_overflow_mode=break is incompatible with the query cache
  # (QUERY_CACHE_USED_WITH_NON_THROW_OVERFLOW_MODE / code 731 on clusters that
  # enable it by default). Debug probes want fresh reads anyway, so disable it.
  --data-urlencode "use_query_cache=0"
  --data-urlencode "max_threads=${CH_MAX_THREADS}"
  --data-urlencode "default_format=TabSeparatedWithNames"
)

# readonly is opt-in. The connecting user should already be a read-only account
# (that is the real guardrail). For such a user, sending any `readonly` value
# fails with "Cannot modify 'readonly' setting in readonly mode" (code 164), so
# we only send it when CH_READONLY is explicitly set — and LAST, because once
# readonly takes effect no further settings can be changed.
if [ -n "${CH_READONLY:-}" ]; then
  settings+=(--data-urlencode "readonly=${CH_READONLY}")
fi

# -G is critical: it forces every --data-urlencode field into the URL query
# string. ClickHouse reads settings (and the query) ONLY from URL params; the
# POST body is treated as raw SQL. Without -G these fields land in the body and
# ClickHouse tries to parse `max_memory_usage=...&...` as a query (SYNTAX_ERROR).
run_curl() {
  curl -sk -m "$((CH_MAX_TIME + 10))" "${auth[@]}" -G "$CH_URL/" \
    "${settings[@]}" \
    --data-urlencode "query=${sql}"
}

# Run it, retrying ONCE on a transient curl failure (DNS / connect / TLS reset /
# empty reply). Those are sandbox/resolver hiccups, not a real outage — a clean
# retry usually succeeds and saves a wasted round-trip of "is the endpoint down?".
# A capped-query error is NOT a curl failure; it comes back as a 200 body below.
resp=""; rc=0
resp="$(run_curl)" || rc=$?
case "$rc" in
  6|7|28|35|52|56)   # 6 DNS, 7 connect refused, 28 timeout, 35/52/56 TLS/empty
    echo "chq.sh: transient curl failure (exit $rc); retrying once..." >&2
    sleep 2
    resp=""; rc=0
    resp="$(run_curl)" || rc=$?
    ;;
esac

printf '%s' "$resp"
[ -n "$resp" ] && printf '\n'

# Surface a targeted hint when a SAFETY CAP tripped, so the next call narrows the
# window / raises the right knob instead of re-guessing. Fan-out
# (clusterAllReplicas) multiplies rows/bytes scanned by node count, so on a large
# fleet these trip far sooner than on one node — narrow the time window FIRST,
# then raise the named cap inline for that one call.
case "$resp" in
  *"Code: 158"*) echo "chq.sh: hit max_rows_to_read (CH_MAX_ROWS=${CH_MAX_ROWS}). Narrow the time window, then raise CH_MAX_ROWS for this call. clusterAllReplicas multiplies rows by node count." >&2 ;;
  *"Code: 307"*) echo "chq.sh: hit max_bytes_to_read (CH_MAX_BYTES=${CH_MAX_BYTES}). Narrow the time window, then raise CH_MAX_BYTES for this call. clusterAllReplicas multiplies bytes by node count." >&2 ;;
  *"Code: 159"*) echo "chq.sh: hit max_execution_time (CH_MAX_TIME=${CH_MAX_TIME}s). Narrow the query or raise CH_MAX_TIME for this call." >&2 ;;
  *"Code: 160"*) echo "chq.sh: rejected by max_estimated_execution_time (CH_MAX_EST_TIME=${CH_MAX_EST_TIME}s) before running. Narrow the time window or raise CH_MAX_EST_TIME." >&2 ;;
  *"Code: 241"*) echo "chq.sh: hit max_memory_usage (CH_MAX_MEM=${CH_MAX_MEM} bytes). Narrow the GROUP BY / result, or raise CH_MAX_MEM deliberately for this call." >&2 ;;
esac

# --- eval harness hook: record successful real responses as fixtures ---
if [ "$rc" -eq 0 ] && [ -n "$resp" ]; then
  fixture_capture chq "$sql" "$resp"
fi

exit "$rc"
