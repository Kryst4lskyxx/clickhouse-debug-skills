#!/usr/bin/env bash
# The docs-feedback guard is a bright line, not a judgement call: submit_feedback
# is an outward-facing WRITE to a third party's docs team, made on the operator's
# employer's behalf. A debugging agent never gets to make that call.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
GUARD="$HERE/../hooks/pretooluse-docs-feedback-guard.sh"

# Feed a PreToolUse payload for an MCP tool; return the guard's exit code.
guard_rc() {  # tool-name
  printf '{"tool_name":%s,"tool_input":{"path":"/quickstart","feedback":"typo"}}' \
    "$(printf '%s' "$1" | jq -R -s .)" | bash "$GUARD" >/dev/null 2>&1
  echo $?
}

assert_eq "blocks the docs submit_feedback tool" 2 \
  "$(guard_rc 'mcp__clickhouse-docs__submit_feedback')"

# Deny is keyed on the tool's identity, so it survives a differently-prefixed
# install of the same MCP server (plugin-scoped, renamed server, etc.).
assert_eq "blocks a differently-prefixed submit_feedback" 2 \
  "$(guard_rc 'mcp__plugin_clickhouse_docs__submit_feedback')"

# Read-only docs tools must pass through untouched — the guard exists to stop a
# write, not to make documentation lookup expensive.
assert_eq "allows docs search" 0 \
  "$(guard_rc 'mcp__clickhouse-docs__search_click_house_documentation')"
assert_eq "allows docs filesystem query" 0 \
  "$(guard_rc 'mcp__clickhouse-docs__query_docs_filesystem_click_house_documentation')"
assert_eq "allows context7 query-docs" 0 \
  "$(guard_rc 'mcp__plugin_context7_context7__query-docs')"
assert_eq "allows unrelated tools" 0 "$(guard_rc 'Bash')"

# An unparseable / empty payload must fail OPEN: a guard that hard-fails during an
# incident is worse than the write it prevents.
printf 'not json' | bash "$GUARD" >/dev/null 2>&1
assert_rc "fails open on unparseable payload" 0 $?

# The block reason has to name the rule, since stderr is what the model reads back.
err="$(printf '{"tool_name":"mcp__clickhouse-docs__submit_feedback","tool_input":{}}' \
  | bash "$GUARD" 2>&1 >/dev/null)"
assert_contains "block reason names the tool" "$err" "submit_feedback"
assert_contains "block reason explains it is outbound" "$err" "read-only"

finish "docs-feedback-guard.test.sh"
