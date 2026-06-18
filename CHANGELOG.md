# Changelog

All notable changes to the `clickhouse-debug` skill are documented here.
This project follows [Semantic Versioning](https://semver.org): patch = fixes/wording,
minor = new capability/reference/script, major = breaking behavior or layout change.

## [Unreleased]

_Nothing yet. Add user-visible changes here; a maintainer will cut the next release._

## [0.1.1] - 2026-06-18

Wrapper fixes from a real chproxy-fronted production debugging session, plus
docs for the proxy/fleet realities it surfaced. No methodology changes.

### Fixed
- **`chq.sh` passed settings in the POST body**, which ClickHouse/chproxy parse
  as raw SQL → `Code: 62 ... Syntax error at position 29 (&)`. Settings now ride
  in the URL query string via `curl -G`.
- **`chq.sh` unconditionally sent `readonly=1`**, which a read-only account
  rejects → `Code: 164 ... Cannot modify 'readonly' setting in readonly mode`.
  `readonly` is now opt-in via `CH_READONLY` (default off); the connecting
  read-only account is the real guardrail.
- **`result_overflow_mode=break` collided with the query cache** when a cluster
  enables it by default → `Code: 731 ... use_query_cache and overflow_mode !=
  'throw' cannot be used together`. The wrapper now always sends
  `use_query_cache=0`.
- **`chq.sh` arg parsing assumed a TTY** (`[ -t 0 ]`), so under an agent/CI Bash
  tool it ignored the SQL argument and read an empty query from stdin →
  `Code: 62 ... Empty query`. It now prefers `$1`/`-f` and falls back to stdin.

### Added
- **Heavy-read override path** documented (inline per-call cap overrides) with a
  fan-out caution: `clusterAllReplicas()` multiplies bytes/rows scanned by node
  count (`Code: 307 ... Limit for bytes to read exceeded`).
- **"Single node vs. proxy-fronted fleet" guidance** in `SKILL.md`:
  `query_log`/`parts` land on a random backend through a proxy, so use
  `clusterAllReplicas()` + `hostName()` for fleet/per-node views.
- **Metric-name discovery** tip in `references/cluster-state.md`: match with a
  `__name__` regex through `promq.sh` instead of dumping
  `/api/v1/label/__name__/values` (one huge line that breaks `jq`).

## [0.1.0] - 2026-06-17

Initial public release.

### Added
- **`clickhouse-debug` skill** — diagnose live ClickHouse cluster and query
  incidents from a version-matched source checkout.
  - Outside-view triage over **Prometheus** (`references/cluster-state.md`):
    node up-ness, OOM, CPU/iowait/load, disk health (incl. SATA-vs-NVMe tier
    mismatch), network, bare-metal vs k8s exit codes.
  - Inside-view forensics over read-only `system.*` (`references/query-state.md`):
    `errors`, `query_log` + attribution, `processes`, parts/merges, `replicas`,
    thread-pool & FD exhaustion, `settings`.
  - Source-confirmed root cause (error code → throw site, metric → semantics).
  - Fix-stage routing delegated to the official `clickhouse-best-practices` skill.
- **`scripts/chq.sh`** — read-only ClickHouse HTTP helper with resource caps on
  every query, aligned to the official `agent-query-safety` rule.
- **`scripts/promq.sh`** — Prometheus query helper (instant + range modes).
- Distribution via `npx skills` and the Claude Code plugin marketplace.

[0.1.0]: https://github.com/Kryst4lskyxx/clickhouse-debug-skills/releases/tag/v0.1.0
