# Changelog

All notable changes to the `clickhouse-debug` skill are documented here.
This project follows [Semantic Versioning](https://semver.org): patch = fixes/wording,
minor = new capability/reference/script, major = breaking behavior or layout change.

## [Unreleased]

_Nothing yet. Add user-visible changes here; a maintainer will cut the next release._

## [0.5.0] - 2026-06-24

Add a fixture-replay eval harness so skill changes become measurable and
regression-safe (Phase 1 of the improvements roadmap; see
docs/superpowers/specs/2026-06-24-clickhouse-debug-improvements-design.md).

### Added
- **Capture/replay in the probe scripts** — `CH_CAPTURE_DIR` records a probe's
  output as a fixture; `CH_REPLAY_DIR` returns the fixture with no network. Both
  are inert when unset, so normal debugging is unchanged. Shared logic in
  `scripts/_fixture.sh`; portable sha1 keying on the normalized query.
- **Eval harness** — `evals/run.sh` (scenario → subagent in replay mode →
  transcript) and `evals/judge.sh` (transcript → rubric scorecard), with the
  agent/judge command injectable (`EVAL_AGENT_CMD`/`EVAL_JUDGE_CMD`) for testing.
- **Seed scenario** `range-join-oom`, proven to pass a correct diagnosis and
  fail a neutered one.
- **Shell unit tests** under `scripts/tests/` and `evals/tests/` (no external
  framework).

### Changed
- `.gitignore` now tracks the harness + sanitized fixtures while keeping raw
  captures in the ignored `evals/local/`.

## [0.4.0] - 2026-06-23

Close the one real coverage gap the v0.3.1 transfer test surfaced: the skill had
no first-class Keeper/ZooKeeper playbook, so a Keeper-restart read-only incident
(replicas read-only, hanging `ON CLUSTER` DDL, `KEEPER_EXCEPTION` storms) was
handled only by the general method with no dedicated `system.*` recipes, no
read-only recovery guidance, and none of the Keeper error codes in the orientation.
All new content is source-confirmed against a local checkout at **v25.8.11.66-lts**.

### Added
- **`references/keeper-state.md`** — a cross-cutting Keeper / ZooKeeper &
  read-only-replica playbook spanning Outside→Inside→Confirm for one incident
  family: the core read-only mechanism (a `ReplicatedMergeTree` table goes
  read-only on lost Keeper session and self-clears on re-init —
  `ReplicatedMergeTreeRestartingThread.cpp`); the Keeper error family in
  `system.errors` (`KEEPER_EXCEPTION`, `TABLE_IS_READ_ONLY`, `NO_ZOOKEEPER`,
  `ALL_CONNECTION_TRIES_FAILED`, `NOT_A_LEADER`, `NO_ACTIVE_REPLICAS`); the inside
  probes (`system.zookeeper_connection`, `system.replicas`,
  `system.replication_queue`, `system.distributed_ddl_queue`, and the `path`-bound
  `system.zookeeper`); the correct Keeper/replication metric families in
  Prometheus; Keeper four-letter-word health (`mntr`/`ruok`); source anchors; and
  an **operator-side recovery ladder** (`SYSTEM RESTART/RESTORE/SYNC REPLICA`,
  recommended not run, since the skill is read-only by construction).
- **`SESSION_EXPIRED` is not a ClickHouse error code** — taught in
  `keeper-state.md` and `references/source-map.md`: it's
  `Coordination::Error::ZSESSIONEXPIRED` surfaced via `KEEPER_EXCEPTION`, so
  grepping `ErrorCodes.cpp` for it returns nothing.
- **Integrations:** a routing-table row + reference-list entry + triage note +
  discovery keywords in `SKILL.md`; a Keeper lead-pointer in the
  `references/query-state.md` replication section; Keeper source-map rows and a
  `KEEPER_EXCEPTION`/`TABLE_IS_READ_ONLY` worked example in
  `references/source-map.md`.

### Fixed
- **Metric-family prefix bug** in `references/cluster-state.md`:
  `ReplicasMaxQueueSize` / `ReplicasMaxAbsoluteDelay` are **async** metrics
  (`ClickHouseAsyncMetrics_`, from `ServerAsynchronousMetrics.cpp`), not
  `ClickHouseMetrics_` — querying the wrong prefix returns 0 series, which reads
  as a false zero (the skill's own "a metric lives in one family" rule).

## [0.3.1] - 2026-06-23

Generalization pass. Subagent testing against the current skill (an anchoring
scenario and an un-anecdoted transfer scenario) showed the transferable method
spine works, but two wrong-shape issues hurt generality: incident numbers read as
**thresholds** rather than as one observed instance (an agent anchored on the
doc's `e.g. 3000` and burned effort instead of confirming the real value), and the
references skewed toward a few rehearsed incident families (failing-merge /
dead-disk / SATA-NVMe, Kafka throughput, OOM-culprit, admission-stampede), risking
misdirection on unrelated incidents. Documentation/methodology only — **no
numbers removed, no script behavior changes.**

### Changed
- **Reframed every incident-specific number as a marked illustration** across
  `SKILL.md`, `references/query-state.md`, and `references/cluster-state.md`: each
  block now leads with the general rule/mechanism and attaches the case figure as
  `(observed once: …)`, so the magnitude still teaches without reading as a fixed
  threshold (`~80M rows/node`, `2–6×` divergence, `≈257k vs 7.26M`, pool size
  `16 vs 32`, `tens of millions` of `FILE_DOESNT_EXIST`, `~10x` iowait, the
  query-driven-OOM `MemAvailable` collapse, `1% used` bitmap corruption, the
  admission-stampede `CurrentMetric_Query` spike).
- **Relabeled `parts_to_throw_insert` as a per-cluster default to confirm** (via
  `system.server_settings`), not a fixed `3000`/`300` — in `references/query-state.md`,
  `references/cluster-state.md`, and `references/source-map.md`. This was the
  sharpest anchoring trap in testing.
- **Broadened the "Capturing what you learn" example set** in `SKILL.md` beyond the
  three rehearsed families (added contaminated metric, missing/mis-owned counter,
  lost Keeper session) so no single incident family dominates the surface.

### Deferred
- **A first-class Keeper / ZooKeeper read-only playbook** (`system.zookeeper_connection`,
  `system.distributed_ddl_queue`, `KEEPER_EXCEPTION` / `SESSION_EXPIRED` /
  `TABLE_IS_READ_ONLY` codes, read-only recovery) — the one real coverage gap the
  transfer test surfaced. Tracked for v0.4.0; out of scope for this generalization
  pass.

## [0.3.0] - 2026-06-22

Harden the skill against a real large-fleet Kafka-ingest investigation whose
costliest miss was trusting one view's rate number: an external Prometheus
consumer-offset metric was treated as throughput ground truth far too long while
it faked plateaus and overstated ~2×, disagreeing with `part_log` rows-written by
2–6×. The headline addition makes external/internal **cross-validation** a rule;
the rest bakes in the `system.*` and Prometheus gotchas the incident surfaced.
Documentation/methodology only — no script behavior changes.

### Added
- **Cross-validation rule + ground-truth hierarchy** in `SKILL.md`: Outside and
  Inside must *agree* before any throughput/rate/lag claim, not be trusted in
  relay. When they disagree, resolve in order — `part_log` rows actually written
  (wins every time) → internal `system.*` counter (verify it exists and covers
  your path) → external Prometheus gauge/offset (sampled, lags, fakes plateaus).
- **Clock-alignment habit** in `SKILL.md`: reconcile the timezone offset between
  Prometheus epochs, your shell, and the server's `now()` before carrying a window
  from one view to another.
- **Prometheus-scope check** in `references/cluster-state.md`: verify the target
  is actually scraped by *this* Prometheus before mapping its labels — a fleet
  runs several Prometheis and the node may simply be absent (0 series ≠ down node).
- **Metric-family note** in `references/cluster-state.md`: a name usually lives in
  exactly one family (`BackgroundMessageBrokerSchedulePoolTask` is a
  `ClickHouseMetrics_*` CurrentMetric gauge, not `ClickHouseAsyncMetrics_*`);
  0 series in one family ≠ absent.
- **"Discover column / ProfileEvent names — never guess"** section in
  `references/query-state.md`: many expected counters don't exist (there is no
  Kafka poll-time counter) and a guessed name reads like zero; list real names via
  `system.columns`/`system.events`/`system.metrics` first. Cross-referenced from
  `references/source-map.md`.
- **"Throughput ground truth: part_log rows written"** section in
  `references/query-state.md`: the `part_log` rows-written recipe as the
  tiebreaker, with the **Kafka caveat** that `metric_log` Kafka ProfileEvents
  badly undercount the background-insert path (≈257k seen vs 7.26M written) —
  prefer `part_log` for volume and `query_views_log` for the insert/MV path (clean
  insert-concurrency proof: max concurrent inserts = number of consumers).
- **Shared-resource attribution check** in `references/query-state.md`: confirm
  the table/metric you measure isn't *also* driven by production on the same node
  before crediting a number to your test; measure a test-exclusive signal or
  report the number as contaminated.
- **`server_settings` vs `settings` for pool sizing** in
  `references/query-state.md`: read `system.server_settings` for anything that
  sizes a pool or the server (one cluster showed pool size 16 in the profile while
  the server ran 32).
- **"ClickHouse SQL gotchas that cost a retry"** section in
  `references/query-state.md`: aggregate-alias shadowing, nested aggregates, and
  `ANY LEFT JOIN` subquery aliasing.

### Changed
- **`text_log` availability guidance** in `references/query-state.md` now says to
  check it *early* and names the fallback when it's off: a source-derived
  conclusion (cite the matched-tree branch), labelled as source-derived rather
  than log-confirmed.

## [0.2.0] - 2026-06-18

Harden the skill against the friction surfaced by a real large-fleet,
chproxy-fronted investigation: fleet-scale resource caps, silent metric NAs, transient
connectivity, shell-state loss across agent Bash calls, and config contamination
from the wrapper's own caps. Scripts gain self-diagnosing behavior; the references
gain the two recipes that incident most wanted.

### Added
- **`chq.sh` cap-trip hints.** When a safety cap aborts a query, the wrapper now
  prints a one-line stderr hint naming the exact knob to raise (`max_rows_to_read`
  → `CH_MAX_ROWS`, and likewise for bytes/time/estimated-time/memory) and reminds
  that `clusterAllReplicas` fan-out multiplies the scan — so the next call narrows
  the window instead of re-guessing.
- **Transient-failure retry in both scripts.** `chq.sh` and `promq.sh` retry once
  on a transient curl failure (DNS/connect/TLS reset), so a sandbox/resolver
  hiccup (curl exit 6/7) no longer costs a round-trip or reads as an outage.
- **`promq.sh` empty-result + error detection.** Distinguishes `0 series` (a
  wrong/absent metric name — the classic silent NA) from a real value of 0, prints
  a discovery hint, surfaces Prometheus in-band query errors, and no longer crashes
  `jq` on an empty/non-JSON body (the cause of tracebacks inside snapshot loops).
- **Fleet-aware cap recipe** in `SKILL.md`: discover node count, narrow the window
  first, then scale `CH_MAX_ROWS`/`CH_MAX_BYTES` to the fleet — with a worked
  6h-across-the-fleet `query_log` example. The default `1e9` row cap is sized for
  one node and trips immediately on a large `clusterAllReplicas` scan (`Code: 158`).
- **Per-node iowait + disk-straggler recipe** in `references/cluster-state.md`:
  the `avg by (instance)` per-core iowait fraction that actually works on bare
  metal, `max by (instance)` to collapse per-device disk metrics to one number per
  node, a note that `ClickHouseProfileEvents_OSIOWaitMicroseconds` / `LoadAverage1`
  often don't discriminate, and the latency-profile proxy (healthy p50 / fat p999
  on slow media) as the fallback disk-straggler signal.
- **Per-node latency-profile query** in `references/query-state.md`
  (p50/p99/p999 by `hostName()` over `clusterAllReplicas`) — the inside-view side
  of the disk-straggler proxy, cross-linked from the Prometheus playbook.
- **Shell-persistence guidance** in `SKILL.md`: exported vars do **not** survive
  between agent Bash calls (only the working directory does), so the Setup step now
  writes a gitignored `.chenv` and `source`s it per call. `.chenv` added to
  `.gitignore` (it holds the CH password).

### Changed
- **Cap-contamination warning.** The wrapper's caps (`max_threads`,
  `max_memory_usage`, …) appear in `system.query_log.Settings` of every probe;
  `SKILL.md`, `references/query-state.md`, and the `chq.sh` header now warn against
  reading those back as production config (read `system.settings` instead). A past
  memory note had recorded the wrapper's `max_threads=4` cap as the real value.
- **README** helper descriptions updated for the new script behavior; dropped the
  stale `readonly=1` mention (the wrapper no longer sends it by default).

## [0.1.2] - 2026-06-18

Integrate the Altinity companion skills and deepen the source-confirmation step
that distinguishes this skill. Documentation/methodology only — no script behavior
changes.

### Added
- **Companion-skill integration with the Altinity skills.** Diagnosis now routes
  into two more suites alongside `clickhouse-best-practices`, turning the companion
  model into three tiers (Fix canon / diagnosis depth / cluster map):
  - **`altinity-expert-clickhouse-*`** (per-domain `system.*` specialists) — the
    Inside stage gains a symptom→specialist routing table (caches, dictionaries,
    kafka, mutations, grants, index-analysis, ingestion, reporting, schema, storage,
    part-log, metrics, logs, security), with the standing rule that any borrowed SQL
    is re-run through `chq.sh` so the `agent-query-safety` caps apply — the
    specialists assume an uncapped MCP/`clickhouse-client` session.
  - **`altinity-profiler-clickhouse`** — a per-cluster `<cluster>-analyst` schema
    map consulted in the Frame stage when a diagnosis depends on table/engine/key
    facts.
- **Install instructions** for both Altinity suites in `SKILL.md` and `README.md`,
  and a "detecting them" check so the skill degrades gracefully when a suite is
  absent. Normalized the `clickhouse-best-practices` install path to
  `clickhouse/agent-skills` across both files.
- **`references/source-map.md`** — a Confirm-stage playbook for navigating the
  matched ClickHouse source tree: version-match check, error-code → throw-site grep
  patterns, metric/setting/`system.*`-column lookup locations, crash-mechanism
  pointers, a "where things live" map, and worked examples for the codes the skill
  names. Source confirmation is now the skill's sole differentiator (diagnosis depth
  → `altinity-expert-*`, remedies → `clickhouse-best-practices`), so it gets its own
  reference and a prominent pointer from the "Confirming against the source" section.

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
