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
