# clickhouse-debug improvements — design

**Date:** 2026-06-24
**Status:** Approved (brainstorm) — ready for implementation planning
**Scope:** A phased roadmap improving the `clickhouse-debug` skill along three tracks — testing/evals, coverage, and ergonomics — structured so no new diagnostic content ever ships without a way to measure it.

---

## 1. Goal & guiding principle

Make `clickhouse-debug` measurably better without ever shipping new diagnostic
content that lacks a scoreboard. Today, improvements are validated by ad-hoc
subagent runs (the changelog references an "anchoring scenario" and a "transfer
scenario"); there is no repeatable harness, so coverage and ergonomics changes
cannot be measured and regressions cannot be caught.

The organizing idea: **build a thin eval harness first, then deliver every later
unit as a self-contained, measured vertical slice.**

This honors the repo's existing values:
- **Source confirmation is the differentiator** — every root-cause mechanism is
  confirmed against the matched-version ClickHouse source (`file:line`).
- **Read-only by construction** — nothing here adds any mutating capability.
- **Small, source-confirmed, releasable-on-`main` PRs** — each slice is
  independently reviewable and keeps `main` releasable.

## 2. Chosen approach

**Approach C — Hybrid: thin harness skeleton first, then vertical slices.**

Rejected alternatives:
- **A (Evals-first foundation):** full harness, then all ergonomics, then all
  coverage. Most regression-safe but front-loads a big-bang harness build,
  designs the harness before real scenarios exist, and delays the first
  diagnostic win.
- **B (Coverage-first):** four playbooks now, evals retrofitted. Fastest visible
  value, but writes content with no scoreboard — the exact condition that
  produced the wrong-shape/anchoring problems the changelog already had to fix.

C captures A's "evals make it safe" property without A's big-bang build, and
avoids B's unmeasured-content risk. The harness grows from real scenarios.

## 3. Phasing

- **Phase 1 — Eval foundation** (one PR). `--capture`/replay mode in `chq.sh` +
  `promq.sh`, a fixture-replay runner, an LLM-judge + rubric format, and one
  seeded scenario built from an existing signature (range-JOIN OOM), to prove
  the harness end-to-end before it carries new work.
- **Phase 2 — Coverage slices** (four PRs, one per domain): distributed-query,
  S3/storage-tiering, async-insert/MV-cascades, BACKUP/RESTORE.
- **Phase 3 — Ergonomics slices** (three PRs): bootstrap/topology discovery,
  one-shot triage snapshot, token/context-cost cut. (Capture mode lands in
  Phase 1.)

## 4. The vertical-slice template

Every Phase 2/3 PR must contain all of:

1. **The change** — a new reference playbook, or a new/edited script.
2. **Source confirmation** — every root-cause mechanism cites `file:line` in a
   matched checkout; the ClickHouse version used is stamped in the slice.
3. **≥1 eval scenario** — prompt + sanitized fixtures + rubric — that fails
   before the slice and passes after.
4. **SKILL.md integration** — routing-table row, reference-list entry,
   discovery keywords added to the `description`, and `source-map.md` additions
   (new error codes / source anchors).
5. **Release hygiene** — CHANGELOG entry + version bump across the existing 5
   version locations (per `scripts/bump-version.sh`).

## 5. Phase 1 — eval harness (fixture replay)

### 5.1 Capture/replay in the scripts

Add two env-gated modes to `chq.sh` and `promq.sh`, leaving normal operation
byte-for-byte unchanged when neither is set:

- **`CH_CAPTURE_DIR=<dir>`** — after a real probe returns, write its output to
  `<dir>/<hash>.tsv` and append `<hash> \t <original query>` to
  `<dir>/index.tsv`. `hash` = sha1 of the normalized query string (collapse
  runs of whitespace, trim) combined with the script name (`chq`/`promq`), so
  the two scripts never collide. This is also the ergonomics "capture mode"
  deliverable.
- **`CH_REPLAY_DIR=<dir>`** — skip the network entirely; compute the same hash
  and return the matching fixture. On a miss, exit non-zero and print
  `no fixture for: <query>` to stderr. A miss is **signal**: either the scenario
  needs that capture, or the agent diverged from the expected probe path.

The same hashing code path is shared by capture and replay so a captured probe
is guaranteed to replay.

**Known limitation (accepted for Phase 1):** the agent may phrase a probe
slightly differently than what was captured (e.g. `INTERVAL 10 MINUTE` vs
`15 MINUTE`). Phase 1 uses exact-normalized matching and treats misses as
visible failures. Fuzzy/semantic fixture matching is **deferred** (YAGNI until a
real scenario demands it).

### 5.2 Scenario format

One directory per scenario:

```
evals/scenarios/<slug>/
  meta.yaml        # CH version, deployment (k8s | bare-metal), domain tag
  prompt.md        # the incident as a user would report it + the setup line
  fixtures/        # captured chq/promq outputs + index.tsv (sanitized)
  rubric.md        # graded expectations (see 5.3)
```

### 5.3 Rubric criteria

Each criterion is graded pass/fail by an LLM judge:

- **Root-cause mechanism** identified correctly (the mechanism, not the symptom).
- **Required evidence present**, including **≥1 `source file:line`** citation.
- **Required rule-outs** stated (branches the evidence eliminates).
- **Anti-pattern checks** — encoding the lessons already in the changelog/memory:
  - Did NOT anchor on a fixture's literal number as if it were a threshold.
  - Did NOT average two disagreeing rates; resolved to ground truth
    (`part_log` rows-written / `query_log.written_rows` first).
  - Did NOT assert a mechanism with no source cite.

### 5.4 Runner + judge

- **`evals/run.sh <scenario>`** — dispatches a subagent with the skill loaded,
  the scripts pointed at the scenario's `fixtures/` via `CH_REPLAY_DIR`, and
  `prompt.md` as the task; saves the transcript.
- **`evals/judge.sh <scenario> <transcript>`** — runs an LLM judge with
  `rubric.md`, emitting a per-criterion pass/fail table + an overall score.

Both are thin wrappers; the judge prompt is the real artifact under review.

### 5.5 Repo layout & gitignore resolution

Today `evals/` is entirely gitignored ("never commit real cluster telemetry").
The harness, scenario prompts, rubrics, and sanitized fixtures must be committed
to be shareable and CI-able. Resolution:

- **Un-ignore** the harness (`evals/run.sh`, `evals/judge.sh`, judge prompt) and
  `evals/scenarios/**`.
- **Hard rule:** committed fixtures are **synthetic or sanitized** — no real
  hostnames, IPs, tenant IDs, or data values; only the structural/numeric shapes
  the diagnosis needs.
- Keep a still-ignored **`evals/local/`** for raw captures from real clusters;
  `--capture` (`CH_CAPTURE_DIR`) defaults there.
- Add a **sanitization checklist** to `CONTRIBUTING.md`.

This preserves the "no real telemetry in git" guarantee while making the harness
a committed, reviewable asset.

### 5.6 Phase-1 exit criterion

The range-JOIN-OOM scenario runs green end-to-end (`run.sh` → `judge.sh`), and
deliberately breaking the skill's relevant guidance makes it go red. This proves
the harness *discriminates* before any new content rides on it.

## 6. Phase 2 — coverage slices (four new playbooks)

Each domain becomes its own focused reference file (consistent with the existing
one-file-per-domain pattern and the "many small files" rule). References are
lazy-loaded — the agent reads only the file the symptom routes to — so new files
add ~no upfront context cost; only the small SKILL.md routing rows grow. Each
ships as a vertical slice (§4).

- **`references/distributed-state.md`** — Distributed-engine fan-out /
  scatter-gather. Probes: `system.clusters`; per-shard `query_log` via
  `clusterAllReplicas` with `hostName()`; `is_initial_query` /
  `initial_query_id` to separate coordinator from remote-leg queries; hedged
  requests and `prefer_localhost_replica` behavior; partial-result /
  `SOCKET_TIMEOUT` / `ALL_CONNECTION_TRIES_FAILED` on remote legs. Source:
  distributed query planning + hedged-connection throw sites.
- **`references/storage-state.md`** — S3 / object storage & tiering. Probes:
  `system.disks`, `system.storage_policies`, `part_log` move events, S3-related
  `ProfileEvents` (request counts / throttling / retries), zero-copy-replication
  lock contention, cold-storage read stalls. Source: disk/object-storage
  throttle + zero-copy lock sites.
- **`references/ingest-pipeline-state.md`** — Async inserts & MV cascades.
  Probes: `asynchronous_insert_log` (flush latency, squashing, dedup); MV chain
  mapping via `system.tables` dependencies; MV push failures surfacing on the
  *insert*; blocking-MV detection. Source: async-insert flush path + MV push
  mechanism. Routes the *fix* to existing `insert-*` best-practice rules.
- **`references/backup-state.md`** — BACKUP/RESTORE. Probes: `system.backups`
  (status / error / progress), restore-in-progress load impact, stuck/failing
  backup attribution. Source: backup status/throw sites.

**Cross-cutting for all four:** every mechanism claim is source-confirmed at the
cluster's matched version, version stamped in the slice; new error codes added
to `source-map.md` and to the `description` keywords; any borrowed Altinity SQL
is re-run through `chq.sh` (caps + `clusterAllReplicas`).

**Ordering:** distributed → storage → ingest → backup (most-common incident
first). Independent; reorderable.

## 7. Phase 3 — ergonomics slices

Capture mode already landed in Phase 1.

- **`scripts/bootstrap.sh`** — one-shot setup + topology discovery. Takes / 
  prompts for `PROM`, `CH_URL`, creds; writes `.chenv` (chmod 600, gitignored).
  Then discovers and prints a topology summary: cluster name(s)
  (`system.clusters`); node count + per-node `version()` / `uptime()` via
  `clusterAllReplicas(..., system.one)`; running version vs the source tree's
  `cmake/autogenerated_versions.txt` (flags a mismatch loudly); and a
  best-effort Prometheus label-scheme probe (which labels carry cluster
  identity). Read-only, capped, fails soft with guidance. Replaces today's
  manual `.chenv` hand-editing and "ask the user to recite the label scheme."
- **`scripts/triage.sh`** — cheap-signal-first snapshot in one pass: Prometheus
  `up` / `MemAvailable` / OOM + recent restarts, then capped `chq.sh` probes for
  `system.errors` (recent), `parts` count, active `merges`, `replicas`
  read-only/queue. Prints a compact ruled-in / ruled-out table to seed the
  funnel — codifying the "prefer the cheap signal first" rule. Honors
  `clusterAllReplicas` when proxy-fronted.
- **Token/context-cost cut** — done last, measured against the harness. Trim
  `SKILL.md` toward a lean orchestration spine; split any oversized reference
  into smaller symptom-scoped sub-files so the agent loads less per
  investigation. **Guardrail:** the restructure must keep all Phase-1/2 eval
  scenarios green — proving bytes were cut without cutting capability. (This is
  why token-cut is sequenced after evals exist.)

## 8. Success criteria

- **Phase 1:** harness discriminates — the seeded scenario goes green; an
  injected regression goes red.
- **Phase 2:** each new domain has ≥1 scenario that fails before / passes after
  its slice; every mechanism source-cited.
- **Phase 3:** `bootstrap.sh` + `triage.sh` exist and are documented in
  SKILL.md/README; token-cut lands with all prior scenarios still green and a
  measured before/after context reduction.

## 9. Out of scope (YAGNI)

- Live ephemeral-cluster evals (docker-compose + fault injection).
- Fuzzy/semantic fixture matching.
- Auto-running evals in CI — the harness is runnable; wiring GitHub Actions is a
  later call.
- Any write/mutating capability — the skill stays read-only by construction.
- Re-deriving fixes the companion skills own (`clickhouse-best-practices`,
  Altinity suites).

## 10. Deliverables

A single phased spec (this doc). Phase 1 is detailed to implementation-ready;
Phases 2–3 are specified at the slice level, each becoming its own follow-up
implementation plan. Implementation begins with Phase 1.
