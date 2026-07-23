#!/usr/bin/env bash
# Asserts the public SKILL.md documents the optional internal context companion.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
SKILL="skills/clickhouse-debug/SKILL.md"
fail=0

grep -q "orgname-clickhouse-context" "$SKILL" || {
  echo "FAIL: SKILL.md must name the internal companion (orgname-clickhouse-context)"; fail=1; }
grep -q "internal" "$SKILL" || {
  echo "FAIL: SKILL.md must describe the companion as internal/optional"; fail=1; }
# The gather-inputs integration must say facts come from the companion when present.
grep -qi "application index" "$SKILL" || {
  echo "FAIL: SKILL.md must reference resolving via the application index"; fail=1; }
# Detection parity: the private companion must be checked with the same explicit
# present/missing rigor as the 3 public companions, not left to a passive mention.
grep -q '\*-clickhouse-context' "$SKILL" || {
  echo "FAIL: SKILL.md's Detecting-them check must include the *-clickhouse-context pattern"; fail=1; }
PREFLIGHT="skills/clickhouse-debug/scripts/preflight.sh"
grep -q '\*-clickhouse-context' "$PREFLIGHT" || {
  echo "FAIL: preflight.sh's companion reminder must include the *-clickhouse-context pattern"; fail=1; }

[ "$fail" -eq 0 ] && echo "PASS: companion-doc.test.sh"
exit "$fail"
