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
assert_eq "allows curl+chq.sh chain" 0 \
  "$(guard_rc 'curl -sk http://h:8123/?query=SELECT%201 | ./chq.sh "SELECT 2"')"
assert_eq "ignores non-CH curl with query" 0 \
  "$(guard_rc 'curl -sk "http://api.example.com/x?query=1"')"
assert_eq "ignores plain bash" 0 \
  "$(guard_rc 'ls -la && echo hi')"

# Verify block reason mentions chq.sh on stderr.
block_err="$(printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
  "$(printf '%s' 'curl -sk http://h:8123/ --data-urlencode "query=SELECT 1"' | jq -R -s .)" | \
  bash "$GUARD" 2>&1 >/dev/null)"
assert_contains "block reason mentions chq.sh" "$block_err" "chq.sh"

finish "guard.test.sh"
