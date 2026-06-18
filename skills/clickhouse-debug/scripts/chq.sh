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
#   # Optional overrides (sane safe defaults below):
#   export CH_MAX_MEM=$((20*1024*1024*1024))         # 20 GiB per-query cap
#   export CH_MAX_TIME=30                            # seconds
#   export CH_MAX_ROWS=$((200*1000*1000))            # max rows to read
#
# Usage:
#   ./chq.sh "SELECT count() FROM system.parts"
#   echo "SELECT ..." | ./chq.sh           # read SQL from stdin
#   ./chq.sh -f query.sql
#
# Output defaults to TabSeparatedWithNames. Append your own FORMAT to override.

set -euo pipefail

CH_URL="${CH_URL:?set CH_URL, e.g. export CH_URL=http://node:8123}"
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

auth=(-u "${CH_USER}:${CH_PASS}")

# -G is critical: it forces every --data-urlencode field into the URL query
# string. ClickHouse reads settings (and the query) ONLY from URL params; the
# POST body is treated as raw SQL. Without -G these fields land in the body and
# ClickHouse tries to parse `max_memory_usage=...&...` as a query (SYNTAX_ERROR).
#
# `readonly=1` must come LAST: ClickHouse applies URL params left-to-right, and
# once readonly=1 is in effect no further settings can be changed. Putting it
# after every cap (and default_format) lets the caps apply first, then locks down.
curl -sk -m "$((CH_MAX_TIME + 10))" "${auth[@]}" -G "$CH_URL/" \
  --data-urlencode "max_memory_usage=${CH_MAX_MEM}" \
  --data-urlencode "max_execution_time=${CH_MAX_TIME}" \
  --data-urlencode "timeout_before_checking_execution_speed=0" \
  --data-urlencode "max_estimated_execution_time=${CH_MAX_EST_TIME}" \
  --data-urlencode "max_rows_to_read=${CH_MAX_ROWS}" \
  --data-urlencode "max_bytes_to_read=${CH_MAX_BYTES}" \
  --data-urlencode "max_result_rows=${CH_MAX_RESULT_ROWS}" \
  --data-urlencode "result_overflow_mode=break" \
  --data-urlencode "max_threads=${CH_MAX_THREADS}" \
  --data-urlencode "default_format=TabSeparatedWithNames" \
  --data-urlencode "query=${sql}" \
  --data-urlencode "readonly=1"
