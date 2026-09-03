#!/usr/bin/env bash
# Claude Code PreToolUse guard for clickhouse-debug: documentation egress.
#
# Blocks ONE tool: the ClickHouse-docs MCP `submit_feedback`. Every other docs tool
# is read-only and passes through untouched.
#
# Why a hard block rather than a prose rule. This skill's documentation lookups are
# read-only to the cluster AND read-only to the docs site — that is the whole safety
# story. `submit_feedback` is the single exception: it WRITES, outward, to a third
# party's docs team, in the middle of an incident, on the operator's employer's
# behalf. That is an outward-facing action a debugging agent should never take
# unilaterally, and unlike query sanitization (a judgement call, taught in SKILL.md)
# it is a bright line with no false positives — so it is worth enforcing mechanically.
#
# Matching is on the tool NAME, suffix-wise, so a differently-prefixed install of the
# same MCP server is still caught.
#
# Block mechanism: exit 2 + reason on stderr (Claude Code feeds stderr back to the
# model so it self-corrects). Reads the hook payload (JSON) on stdin. Fails OPEN on
# anything it can't parse — a guard that hard-fails mid-incident is worse than the
# write it prevents.
set -uo pipefail

input="$(cat)"
tool="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)"

[ -n "$tool" ] || exit 0                        # unparseable -> allow
case "$tool" in *submit_feedback) ;; *) exit 0;; esac

echo "clickhouse-debug: blocked submit_feedback. Documentation lookup in this skill is read-only in both directions; submit_feedback is an outbound WRITE to the ClickHouse docs team and is never the debugging agent's call to make — least of all mid-incident, when the text most likely to be pasted into it is drawn from a production cluster. If a docs page is genuinely wrong, note it in the RCA writeup and let a human file it." >&2
exit 2
