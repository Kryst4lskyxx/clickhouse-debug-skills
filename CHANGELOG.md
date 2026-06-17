# Changelog

All notable changes to the `clickhouse-debug` skill are documented here.
This project follows [Semantic Versioning](https://semver.org): patch = fixes/wording,
minor = new capability/reference/script, major = breaking behavior or layout change.

## [Unreleased]

_Nothing yet. Add user-visible changes here; a maintainer will cut the next release._

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
