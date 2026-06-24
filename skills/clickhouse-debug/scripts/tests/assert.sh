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
