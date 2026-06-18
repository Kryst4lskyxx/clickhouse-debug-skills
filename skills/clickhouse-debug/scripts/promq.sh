#!/usr/bin/env bash
# Query a Prometheus HTTP API and pretty-print results sorted by value desc.
#
# Set the Prometheus base URL once per session:
#   export PROM='https://prometheus.example.com'
#
# Usage:
#   ./promq.sh 'PROMQL'                 -> instant query, table sorted desc
#   ./promq.sh 'PROMQL' range 1h 60s    -> range query (start=now-1h, step=60s), per-series avg/max
#
# Notes:
#   - Internal CAs: this uses `curl -k`. If the egress is sandboxed, run the
#     calling Bash tool with dangerouslyDisableSandbox: true.
#   - Every call has a hard 60s timeout (-m 60) so a slow/huge query can't hang.
#   - Keep ranges short and steps coarse: a 24h range at 15s step on a
#     high-cardinality metric returns a flood. Prefer step >= 60s.

set -euo pipefail

PROM="${PROM:-}"
if [ -z "$PROM" ]; then
  echo "ERROR: set the Prometheus base URL first, e.g. export PROM='https://prometheus.example.com'" >&2
  exit 2
fi

q="${1:?usage: promq.sh 'PROMQL' [range SPAN STEP]}"
mode="${2:-instant}"

# Build the curl args for the chosen endpoint.
if [ "$mode" = "range" ]; then
  span="${3:-1h}"; step="${4:-60s}"
  num=${span%[smhd]}; unit=${span: -1}
  case $unit in s) mul=1;; m) mul=60;; h) mul=3600;; d) mul=86400;; *) mul=1;; esac
  now=$(date +%s); start=$((now - num*mul))
  args=( -G "$PROM/api/v1/query_range"
    --data-urlencode "query=$q" --data-urlencode "start=$start"
    --data-urlencode "end=$now" --data-urlencode "step=$step" )
else
  args=( -G "$PROM/api/v1/query" --data-urlencode "query=$q" )
fi

# Fetch into a var (not a pipe) so we can validate the response BEFORE jq sees it.
# A raw `curl | jq` crashes with a JSONDecodeError-style trace on an empty body —
# which is exactly what a transient timeout inside a loop produces. Retry ONCE on
# a transient curl failure, then fail with a clear message instead of a stack trace.
raw=""; rc=0
raw="$(curl -sk -m 60 "${args[@]}")" || rc=$?
if [ "$rc" -ne 0 ] || [ -z "$raw" ]; then
  echo "promq.sh: transient fetch failure (curl exit $rc); retrying once..." >&2
  sleep 2; raw=""; rc=0
  raw="$(curl -sk -m 60 "${args[@]}")" || rc=$?
fi
if [ "$rc" -ne 0 ] || [ -z "$raw" ]; then
  echo "promq.sh: no response from $PROM (curl exit $rc). Check PROM, network, and sandbox egress (run the Bash tool with dangerouslyDisableSandbox: true)." >&2
  exit 1
fi

# Prometheus reports query errors in-band as {status:"error",error:"..."} with a
# 200, and a proxy/login page can return non-JSON. Catch both before formatting.
status="$(printf '%s' "$raw" | jq -r '.status // "parse_error"' 2>/dev/null || echo parse_error)"
if [ "$status" != "success" ]; then
  msg="$(printf '%s' "$raw" | jq -r '.error // "non-JSON response (auth/proxy page?)"' 2>/dev/null || echo 'non-JSON response')"
  echo "promq.sh: Prometheus query failed: $msg" >&2
  exit 1
fi

# Zero series is NOT an error and NOT a value of 0 — most often the metric name or
# label set just doesn't exist on THIS cluster (metric families vary by build and
# by bare-metal-vs-k8s). Say so loudly so an empty table isn't misread as "it's 0".
n="$(printf '%s' "$raw" | jq -r '.data.result | length' 2>/dev/null || echo 0)"
if [ "$n" -eq 0 ]; then
  echo "promq.sh: 0 series — the metric or label set may not exist here (not a value of 0)." >&2
  echo "  discover names: ./promq.sh 'group by (__name__) ({__name__=~\"<fragment>.*\"})'" >&2
  exit 0
fi

if [ "$mode" = "range" ]; then
  printf '%s' "$raw" \
  | jq -r '.data.result[] | . as $s
      | ([.values[][1]|tonumber] | (add/length) as $avg | (max) as $mx
         | "\($avg)\t\($mx)")
      as $stats | "\($stats)\t\($s.metric|to_entries|map("\(.key)=\(.value)")|join(","))"' \
  | sort -rn -k2 | awk -F'\t' 'BEGIN{printf "%-12s %-12s %s\n","AVG","MAX","SERIES"}{printf "%-12.4f %-12.4f %s\n",$1,$2,$3}'
else
  printf '%s' "$raw" \
  | jq -r '.data.result[] | "\(.value[1])\t\(.metric|to_entries|map("\(.key)=\(.value)")|join(","))"' \
  | sort -rn | awk -F'\t' 'BEGIN{printf "%-14s %s\n","VALUE","SERIES"}{printf "%-14.4f %s\n",$1,$2}'
fi
