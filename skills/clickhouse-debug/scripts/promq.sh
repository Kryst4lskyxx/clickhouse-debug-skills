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

if [ "$mode" = "range" ]; then
  span="${3:-1h}"; step="${4:-60s}"
  num=${span%[smhd]}; unit=${span: -1}
  case $unit in s) mul=1;; m) mul=60;; h) mul=3600;; d) mul=86400;; *) mul=1;; esac
  now=$(date +%s); start=$((now - num*mul))
  curl -sk -m 60 -G "$PROM/api/v1/query_range" \
    --data-urlencode "query=$q" --data-urlencode "start=$start" \
    --data-urlencode "end=$now" --data-urlencode "step=$step" \
  | jq -r '.data.result[] | . as $s
      | ([.values[][1]|tonumber] | (add/length) as $avg | (max) as $mx
         | "\($avg)\t\($mx)")
      as $stats | "\($stats)\t\($s.metric|to_entries|map("\(.key)=\(.value)")|join(","))"' \
  | sort -rn -k2 | awk -F'\t' 'BEGIN{printf "%-12s %-12s %s\n","AVG","MAX","SERIES"}{printf "%-12.4f %-12.4f %s\n",$1,$2,$3}'
else
  curl -sk -m 60 -G "$PROM/api/v1/query" --data-urlencode "query=$q" \
  | jq -r '.data.result[] | "\(.value[1])\t\(.metric|to_entries|map("\(.key)=\(.value)")|join(","))"' \
  | sort -rn | awk -F'\t' 'BEGIN{printf "%-14s %s\n","VALUE","SERIES"}{printf "%-14.4f %s\n",$1,$2}'
fi
