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
