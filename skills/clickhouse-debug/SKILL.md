---
name: clickhouse-debug
description: >-
  Diagnose live ClickHouse cluster and query problems from a checked-out
  ClickHouse source tree, using Prometheus metrics plus read-only queries
  against the cluster's own system.* tables, and confirming every root-cause
  claim against the matched-version source. Use this WHENEVER the user is
  investigating a running ClickHouse cluster: nodes down / flapping / OOM-killed,
  pods crash-looping or OOMKilled, high CPU / iowait / load, merge or part
  pile-ups (TOO_MANY_PARTS), replication lag, replicas stuck read-only / lost
  Keeper (ZooKeeper) sessions / hanging ON CLUSTER DDL, slow or failing queries,
  error storms (CANNOT_SCHEDULE_TASK, MEMORY_LIMIT_EXCEEDED, KEEPER_EXCEPTION,
  TOO_MANY_SIMULTANEOUS_QUERIES, FILE_DOESNT_EXIST), thread-pool exhaustion, FD
  exhaustion, "why did this node fall over", or "what is this query doing". Trigger even when the user just
  pastes an error code, a Prometheus alert, or a node/pod name and asks what's
  wrong. Do NOT use for writing application SQL, schema design, or local
  single-node dev (use clickhouse-best-practices / chdb skills for those).
license: Apache-2.0
metadata:
  author: Ye Yuan
  version: "0.5.0"
---

# ClickHouse cluster & query debugging

This skill turns a checked-out ClickHouse source tree into a live debugging
cockpit. You diagnose a running cluster by reading **Prometheus** (the outside
view — what the OS and the server expose) and the cluster's own **`system.*`
tables over read-only HTTP** (the inside view — what the server is actually
doing), then you **confirm the root cause against the source you're standing in**
(the matched version — error codes, metric semantics, and throw sites are
version-specific and the source removes the guesswork).

The work is read-only by construction. You never mutate the cluster. The one way
a *read* can still hurt a production node is by consuming too much memory/CPU —
so resource safety below is not optional.

## Companion skills (install these first)

This skill owns the *diagnosis* — what's wrong, why, and where in the matched
source. It leans on three companion suites for everything *around* that diagnosis.
Install all three before a real investigation:

```bash
npx skills add clickhouse/agent-skills                                 # Fix canon (best-practices)
npx skills add Altinity/altinity-skills/altinity-expert-clickhouse/    # deeper system.* playbooks
npx skills add Altinity/altinity-skills/altinity-profiler-clickhouse/  # per-cluster schema map
```

**1. `clickhouse-best-practices` (+ `clickhouse-architecture-advisor`) — the Fix
canon.** The canonical, versioned remedy rules maintained by ClickHouse Inc. This
skill does **not** re-derive schema/query/insert guidance. Lean on it in two places:

- **Resource safety** — the rule `agent-query-safety` is the authority for query
  caps; `scripts/chq.sh` implements it. (Also `agent-connect-mcp`,
  `agent-discovery-schema` for connection and schema discovery.)
- **The Fix stage** — when a fix touches schema, query shape, or ingestion,
  invoke it (via the Skill tool) and **cite the specific rule** rather than
  improvising. Mapping in the Fix section below.

**2. `altinity-expert-clickhouse-*` — diagnosis depth (a suite of domain
specialists).** Per-domain `system.*` playbooks (caches, dictionaries, kafka,
mutations, grants, index-analysis, ingestion, reporting, schema, storage, metrics,
part-log, logs, security, …), each shipping ready-made SQL. This skill's own
`references/query-state.md` covers the common incident signatures *with source
confirmation*; route into a specialist when the symptom lands in a domain those
references don't drill. The symptom→specialist table is in the Inside-stage section
below. `altinity-expert-clickhouse-overview` is their entry point (health snapshot +
routing) when you don't yet know the domain.

> **Caps don't travel with their SQL.** The altinity specialists assume an
> *uncapped* MCP / `clickhouse-client` session (`event_date >= today() - 1`,
> `LIMIT 100`, no per-query memory/time/bytes cap). When you borrow one of their
> queries, run it through `chq.sh` (which injects the `agent-query-safety` caps) and
> wrap the table in `clusterAllReplicas(<cluster>, …)` if you're proxy-fronted —
> don't fire it raw at a production node.

**3. `altinity-profiler-clickhouse` — the cluster map (optional, for the Frame
stage).** Generates a per-cluster `<cluster>-analyst` knowledge base (tables,
engines, ORDER BY keys, join map, tenancy, aggregation idioms). It is **not** a live
debugger — but when a diagnosis hinges on schema you don't have memorized ("what
engine is this table, is `FINAL` the read idiom, which column prunes the index"),
load an existing `<cluster>-analyst` skill, or offer to run the profiler once while
the cluster is calm.

**Detecting them:** check your available skills for `clickhouse-best-practices`,
`altinity-expert-clickhouse-overview`, and `altinity-profiler-clickhouse`. If a
suite is genuinely unavailable and the user can't install it now, proceed but **say
so** — your fixes will be uncited general guidance, and your `system.*` drilling will
be limited to this skill's own references.

## Before you touch anything: gather inputs

You need these to start. If any are missing, **ask the user — don't guess**:

1. **The problem.** A symptom, alert, error code, node/pod name, or "this is
   slow". The more concrete the better.
2. **Target cluster + Prometheus.** The Prometheus base URL, and how the
   cluster is labelled there (e.g. `cluster="example-clickhouse"`,
   or by `instance`/`pod`). If unsure of the label scheme, discover it (see
   cluster-state reference) rather than asking the user to recite it.
3. **Direct ClickHouse access.** HTTP endpoint (`http://host:8123` or
   `https://host:8443`) and a **read-only user** + password. If the user only
   has a native-protocol port, prefer HTTP anyway — from a laptop/VPN the native
   client often can't resolve its own hostname.
4. **Deployment type: bare metal or Kubernetes.** This changes which metrics
   exist and what the failure modes look like (a node "down" vs a pod
   crash-looping). If the user hasn't said, **ask** — it's a one-word answer
   that redirects half the playbook.
5. **Source matches the cluster version.** Confirm the checked-out tree is the
   same (or closest) version as the running cluster — `SELECT version()` vs
   `cmake/autogenerated_versions.txt` / `git describe`. If they diverge, say so;
   line numbers and behaviors may differ.

Confirm the gathered setup back to the user in one line before running probes, so
a wrong cluster/endpoint is caught before any query hits production.

## Resource safety (read this — a debug query once OOM-killed a prod node)

Any diagnostic query without a memory cap can exhaust RAM and trip the OS OOM
killer — treat every probe as if it could, because it can. (Observed once: an
accidental cross-join — a range-JOIN on `asynchronous_metric_log` — did exactly
that to a production node.)

The canonical rule for this is `agent-query-safety` in the official
`clickhouse-best-practices` skill — read it if in doubt; the rules below are the
debugging-specific application of it.

Non-negotiable rules:

- **Always cap memory and time per query.** Use `scripts/chq.sh`, which injects
  `max_memory_usage`, `max_execution_time` (with
  `timeout_before_checking_execution_speed=0` so it's a true wall clock),
  `max_estimated_execution_time` (rejects doomed queries before they start),
  `max_rows_to_read`, `max_bytes_to_read`, `max_result_rows`, `max_threads`, and
  `use_query_cache=0` on every call — exactly the `agent-query-safety` settings.
  Don't hand-roll bare `curl` to the cluster unless you replicate those caps.
- **Connect with a read-only account** — that's the real write guardrail. The
  wrapper does NOT send `readonly=1` by default, because a properly read-only
  user (a `readonly=1`/`readonly=2` profile) rejects it with
  `Cannot modify 'readonly' setting in readonly mode` (code 164). Only set
  `CH_READONLY=1` if you must connect with a read-write account.
- **Filter `system.*` log tables by time first, in a subquery, before any join
  or heavy aggregation.** `query_log`, `metric_log`, `asynchronous_metric_log`,
  `trace_log`, `part_log` are huge. `WHERE event_time > now() - INTERVAL 10 MINUTE`
  belongs in the innermost scan, not the outer query.
- **Never range-JOIN** (`JOIN ... ON a.t >= x AND a.t <= y` with no equality
  key) — it's a cross product. Bucket by time key and equi-join, or window in a
  subquery first.
- **Always `LIMIT`** exploratory result sets. You want shapes and magnitudes,
  not full dumps.
- **Keep Prometheus ranges short and steps coarse** (step ≥ 60s for multi-hour
  ranges). `scripts/promq.sh` hard-times-out at 60s.
- **Prefer the cheap signal first.** A single `system.metric_log` row or one
  `up`/`MemAvailable` series usually rules out whole branches before you run any
  expensive aggregation.

If you ever need a heavier query, narrow the time window and raise caps
*deliberately* — inline for the one call so the default stays safe — and tell
the user what you're doing and why:

```bash
# one heavy read, defaults restored on the next call
CH_MAX_BYTES=$((500*1000*1000*1000)) CH_MAX_TIME=60 ./chq.sh "SELECT ..."
```

Every cap is overridable this way: `CH_MAX_MEM`, `CH_MAX_TIME`, `CH_MAX_ROWS`,
`CH_MAX_BYTES`, `CH_MAX_EST_TIME`, `CH_MAX_RESULT_ROWS`, `CH_MAX_THREADS`. When a
cap trips, `chq.sh` prints a one-line stderr hint naming the exact knob to raise
(e.g. `hit max_rows_to_read (CH_MAX_ROWS=...)`) — follow it rather than guessing.

**Fan-out multiplies the scan — the single biggest recurring friction on a large
fleet.** A `clusterAllReplicas(...)` query reads from every node, so rows/bytes
scanned scale with node count. The default `CH_MAX_ROWS=1e9` is sized for one
node; on a 60-node fleet a 2-day shard-level `query_log` scan blows straight past
it (`Code: 158 ... Limit for rows to read exceeded` at ~1B rows) before returning
anything. The fix is **window-first, then scale the cap to the fleet:**

1. **Discover the node count first** (you need it to size the cap):
   `source ./.chenv && ./chq.sh "SELECT count() FROM clusterAllReplicas(<cluster>, system.one)"`.
2. **Narrow the time window hard** — minutes/hours around the incident, not days.
   The window is the cheapest lever; it cuts the scan on every node at once.
3. **Then raise the relevant cap for that one call,** roughly scaled by node
   count: size it to (rows-per-node over your window) × node count, plus headroom
   — measure the per-node rate for your scan rather than assuming a constant.
   (Observed once: a shard-level `query_log` scan ran ~80M rows/node, needing
   `CH_MAX_ROWS ≈ 80M × nodes`.)

```bash
# 6h shard-level query_log scan across a large (60+ node) fleet, rows cap raised for it
source ./.chenv && CH_MAX_ROWS=$((5*1000*1000*1000)) ./chq.sh "
  SELECT hostName(), count(), sum(read_bytes)
  FROM clusterAllReplicas(<cluster>, system.query_log)
  WHERE event_time > now() - INTERVAL 6 HOUR
  GROUP BY hostName()"
```

Raise `CH_MAX_BYTES` the same way for byte-bound scans (`Code: 307`). Keep the
override inline so the safe default is restored on the next call.

**These caps contaminate `query_log.Settings`.** Because the wrapper sends them as
query settings, every probe it runs records `max_threads`, `max_memory_usage`,
etc. in its own `system.query_log` row. Don't read those values back as the
cluster's production config — that's the debug cap, not the server default. To
read real config, query `system.settings` on a normal session (see
`references/query-state.md`, Settings section).

## Setup (once per session)

**Shell state does not persist between Bash tool calls.** The working *directory*
carries over, but `export`ed variables do **not** — each call starts a fresh
shell, so a `PROM`/`CH_URL`/creds `export` in one call is gone by the next, and
the scripts fail with `set CH_URL...`. Write the config to a file once and
`source` it at the start of every call:

```bash
cd <skill-dir>/scripts
cat > .chenv <<'EOF'
export PROM='https://prometheus.example.com'          # from the user
export CH_URL='http://chnode.example.com:8123'         # from the user
export CH_USER='readonly_user'; export CH_PASS='...'   # read-only creds
EOF
chmod 600 .chenv     # it holds a password; .chenv is gitignored
```

Then prefix each later call with `source ./.chenv`:

```bash
source ./.chenv && ./chq.sh "SELECT version()"
source ./.chenv && ./promq.sh 'up{cluster="..."}'
```

(Or inline the vars on the one call: `CH_URL=... CH_USER=... ./chq.sh "..."`.)

- `./promq.sh 'PROMQL'` — instant query, sorted desc.
- `./promq.sh 'PROMQL' range 6h 300s` — range, per-series avg/max.
- `./chq.sh "SELECT ..."` — capped read-only SQL (TSV-with-names).

Both scripts **retry once** on a transient curl failure (DNS/connect/TLS reset) —
a sandbox/resolver hiccup (curl exit 6/7) is not an outage, so don't conclude the
endpoint is down on the first failure. If a probe genuinely can't connect, sanity
-check the endpoint with a raw `curl -sk "$CH_URL/ping"` before re-planning.

Internal CAs + sandboxed egress: run the Bash tool with
`dangerouslyDisableSandbox: true` for these calls (curl already uses `-k`).

### Single node vs. proxy-fronted fleet

`CH_URL` may point at one node **or** at a load balancer / proxy (e.g. chproxy)
in front of dozens of nodes. Find out which early — it changes how you read
`system.*`:

- **Each call may hit a different backend.** A bare `system.query_log` /
  `system.parts` query lands on whichever node the proxy picked, so results are
  non-deterministic and node-local. For any fleet-wide or per-node view, wrap the
  table in `clusterAllReplicas(<cluster>, system.<table>)` and select
  `hostName()` so you know which node each row came from. Get the cluster name
  from `SELECT cluster, count() FROM system.clusters GROUP BY cluster`.
- **Confirm the spread first:** `SELECT hostName(), version(), uptime() FROM
  clusterAllReplicas(<cluster>, system.one)` tells you the node count and whether
  versions/uptimes are uniform.
- **Proxy quirks `chq.sh` already handles:** settings must ride in the URL (not
  the POST body), the `query` cache is often on by default (the wrapper sends
  `use_query_cache=0`), and the proxy user is typically read-only (so no
  `readonly=1`). Don't hand-roll `curl` against a proxy without replicating these.

## The triage workflow

Debugging is a funnel: start broad and cheap, let each signal rule branches in
or out, and only drill where the evidence points. Don't dump every metric — that
buries the signal and burns the cluster.

```
1. Frame      What changed, when, on which node/pod? Get a timestamp.
2. Outside    Prometheus: is it up? OOM? CPU/iowait/mem/disk? cluster-wide vs one node?
              -> references/cluster-state.md
3. Inside     system.* over chq.sh: errors, queries, parts, merges, replicas.
              -> references/query-state.md
4. Confirm    Map the symptom to source in THIS tree (error code -> throw site,
              metric -> what increments it). Don't assert a cause you can't point at.
5. Report     Live narration of what each step ruled in/out, then an RCA writeup.
```

**Cross-validate before you conclude a rate.** Outside and Inside are not a relay
where each view is authoritative in turn — they are two instruments that must
agree before you trust a number. Any throughput / rate / lag claim needs **two
independent views that agree.** If an external metric and an internal counter
disagree (they routinely do, sometimes by multiples; observed once: a
consumer-offset gauge vs `part_log` rows-written diverged 2–6×), don't average
them and don't pick the convenient one. Resolve to ground truth, in order:

1. **`part_log` rows actually written** (or `query_log.written_rows`) — the rows
   that truly landed. This wins every disagreement.
2. **An internal `system.*` counter / `ProfileEvent`** — second, but verify the
   name exists *and* covers your path (the Kafka background-insert counters badly
   undercount; see query-state).
3. **The external Prometheus gauge / consumer-offset** — last. It's sampled, can
   lag, and on short from-earliest windows fakes plateaus and overstates ~2×.

A Prometheus series that *looks* authoritative is the classic trap — confirm it
against the inside view before you build any conclusion on it.

**Align clocks before you align windows.** Prometheus returns Unix epochs; your
shell renders them in its local TZ; the server's `now()` is its own TZ (usually
UTC). Establish the offset between all three up front (`./chq.sh "SELECT now(),
timezone()"` vs `date -u` vs a known Prometheus point) so a window you carry from
one view to another lands on the same wall-clock second.

The reference files are the deep playbooks — three by stage (Outside → Inside →
Confirm) plus one cross-cutting domain file (Keeper / read-only replicas, which
itself spans all three stages). Read the one the symptom points to; you usually
need more than one because real incidents cross the boundary (a node shows down in
Prometheus → you drill into `query_log` to find the query that killed it → you
confirm the throw site in the source).

- **`references/cluster-state.md`** — Outside / Prometheus playbook. Node/pod
  up-ness, OOM, CPU/iowait/load, memory, disk (incl. SATA-vs-NVMe hardware tiers),
  network, `ClickHouseProfileEvents_*` / `Metrics_*` / `AsyncMetrics_*`,
  and the bare-metal vs Kubernetes differences (exit codes, OOMKilled, restart
  counts, cgroup limits).
- **`references/query-state.md`** — Inside / `system.*` playbook. `query_log`
  forensics and attribution (who ran it, from where), `errors`, `parts` / part
  pile-ups, `merges` / `part_log` (failing-merge storms), `replicas` / replication
  lag, `processes` (live queries), thread-pool and FD exhaustion.
- **`references/source-map.md`** — Confirm / source-tree playbook. Where error
  codes, ProfileEvents/metrics, settings, and `system.*` columns live in the tree;
  grep patterns for throw sites; the version-match check; and worked examples for
  the codes this skill names. This is the differentiator — read it whenever you're
  about to assert a mechanism.
- **`references/keeper-state.md`** — Keeper / ZooKeeper & read-only-replica
  playbook (cross-cutting: it walks Outside→Inside→Confirm for one incident
  family). Read it when replicas are stuck **read-only**, `ON CLUSTER` DDL hangs,
  `KEEPER_EXCEPTION` storms, replication stalls "on Keeper", or anything **after a
  Keeper restart**. Covers `system.zookeeper_connection` / `replicas` /
  `replication_queue` / `distributed_ddl_queue`, the Keeper metric families, the
  source mechanism for read-only, and the operator-side recovery ladder.

### Routing into the altinity specialists (deeper system.* playbooks)

`references/query-state.md` is the source-confirmed core. When the symptom is in a
domain it doesn't drill (or you want a second, ready-made query set), invoke the
matching `altinity-expert-clickhouse-*` specialist via the Skill tool — then run any
SQL you adopt through `chq.sh` (caps + `clusterAllReplicas`, per the caveat above),
since the specialists assume an uncapped session.

| Symptom / finding | Specialist |
|---|---|
| Don't know where to start — want a health snapshot | `altinity-expert-clickhouse-overview` |
| Cache hit-ratio / mark / uncompressed / query cache | `altinity-expert-clickhouse-caches` |
| Dictionary load failure / high dictionary memory | `altinity-expert-clickhouse-dictionaries` |
| Kafka engine lag / consumer errors / thread starvation | `altinity-expert-clickhouse-kafka` |
| Stuck or slow mutations (`ALTER UPDATE/DELETE`) | `altinity-expert-clickhouse-mutations` |
| `ACCESS_DENIED` / `AUTHENTICATION_FAILED` / grants after upgrade | `altinity-expert-clickhouse-grants` |
| Scans larger than expected / ORDER BY / skip-index effectiveness | `altinity-expert-clickhouse-index-analysis` |
| Slow `INSERT` / high part-creation rate / batch sizing | `altinity-expert-clickhouse-ingestion` |
| Slow `SELECT` latency / query-pattern analysis | `altinity-expert-clickhouse-reporting` |
| Partitioning / ORDER BY / materialized-view anti-patterns | `altinity-expert-clickhouse-schema` |
| Disk usage / compression / part sizes / slow IO | `altinity-expert-clickhouse-storage` |
| Replicas read-only / hanging `ON CLUSTER` DDL / `KEEPER_EXCEPTION` / post-Keeper-restart | **lead with `references/keeper-state.md`**, then `altinity-expert-clickhouse-replication` |
| `part_log` forensics (micro-batch, merge backlog, znode growth) | `altinity-expert-clickhouse-part-log` |
| Load / connection saturation / queue buildup (live metrics) | `altinity-expert-clickhouse-metrics` |
| System-log TTL / unbounded log growth | `altinity-expert-clickhouse-logs` |
| Security-posture audit (users, grants, exposure) | `altinity-expert-clickhouse-security` |

Overlap, on purpose: **memory, merges, and replication** have both a specialist
*and* a source-confirmed section in `references/`. For those, lead with this skill's
references (they tie the symptom to a `file:line` in the matched tree) and pull the
specialist in for extra SQL or domain breadth. Whatever you route to, the value this
skill keeps is the same: Prometheus correlation, resource-capped HTTP probes, and
confirming the mechanism against the source you're standing in.

## Confirming against the source (the "matched version" step)

This is what separates a guess from a diagnosis. When a symptom names an error
code, a metric, or a specific behavior, find where the running version produces
it:

- **Error code → throw site.** `grep -rn "CANNOT_SCHEDULE_TASK" src/` then read
  the surrounding logic. Error names live in `src/Common/ErrorCodes.cpp`; the
  throw explains the precondition (e.g. `ThreadPool.cpp` shows
  `CANNOT_SCHEDULE_TASK` comes from a failed `std::thread` ctor, not a quota).
- **Metric → meaning.** `grep -rn "ProfileEvents::ContextLock\|Metric.*ContextLock" src/`
  to learn what actually increments it (e.g. ContextLock with ~0 wait time is a
  CPU spin re-acquiring the lock, not lock contention).
- **Behavior / crash → mechanism.** Trace destructors, signal handling, pool
  sizing in source to explain *why* a symptom becomes a crash (e.g. a throwing
  destructor during stack unwinding → `std::terminate` → SIGSEGV).

Cite `file:line` in the writeup. If the source contradicts your hypothesis,
believe the source.

The full navigation playbook — where each of these lives in the tree, the grep
patterns, the version-match check, and worked examples for the codes this skill
names — is **`references/source-map.md`**. Read it before asserting any mechanism;
confirming against the matched source is this skill's one irreplaceable step now
that diagnosis depth and remedies are delegated to the companion skills.

## The Fix stage: route through clickhouse-best-practices

Diagnosis is yours; the *remedy*, when it touches schema/query/ingestion, should
be rule-backed. Invoke `clickhouse-best-practices` and cite the rule by name
("Per `query-join-filter-before`…"). Common debug findings → rules:

| Diagnosis | Consult rule(s) |
|-----------|-----------------|
| Heavy/range-JOIN, cross product, slow JOIN | `query-join-filter-before`, `query-join-choose-algorithm`, `query-join-consider-alternatives` |
| `TOO_MANY_PARTS`, part pile-up, merge backlog | `insert-batch-size`, `insert-async-small-batches`, `schema-partition-lifecycle`, `schema-partition-query-tradeoffs` |
| `OPTIMIZE FINAL` / `FINAL` overuse | `insert-optimize-avoid-final` |
| Mutation storms (`ALTER UPDATE/DELETE`) | `insert-mutation-avoid-update`, `insert-mutation-avoid-delete` |
| Wrong/expensive primary key, poor filtering | `schema-pk-prioritize-filters`, `schema-pk-cardinality-order`, `schema-pk-filter-on-orderby` |
| Wide rows / type bloat / `Nullable` cost | `schema-types-lowcardinality`, `schema-types-avoid-nullable`, `schema-types-minimize-bitwidth` |
| JSON/Dynamic subcolumn fan-out (FD pressure) | `schema-json-when-to-use` |
| Slow scans missing skip indices | `query-index-skipping-indices` |

Operational/infra fixes that best-practices doesn't cover (per-query
`max_memory_usage` caps, `use_hedged_requests`, `max_concurrent_queries`, FD
limits, disk rebuilds, hardware tiers) stay in this skill's references — they're
the levers the diagnosis reference files document.

## Output: live triage, then an RCA writeup

Narrate as you go — for each probe, state what you ran and what it ruled in or
out. This lets the user steer mid-investigation and makes the reasoning
auditable. Then close with:

```
## Root cause
<one or two sentences: the actual mechanism, not the symptom>

## Evidence
- <metric/query result> -> <what it shows>           (with numbers + timestamps)
- <source file:line>    -> <why this is the mechanism>
- <what you ruled out and why> (so it isn't re-investigated)

## Fix (in priority order)
1. <the one change that converts crash -> clean error, or stops the bleeding>
2. <secondary / structural fixes>

## Severity & scope
<one node or fleet-wide? urgent or latent? blast radius>
```

Be honest about uncertainty: if the pre-crash `metric_log` buffer was lost to the
OOM, say the in-server evidence is gone and point at OS logs (`dmesg`, `last`,
`/var/log`) as the next step rather than overclaiming.

## Capturing what you learn

These incidents recur across a fleet. When a diagnosis lands on a non-obvious
mechanism — any cause that wasn't obvious from the symptom (a hardware tier
mismatch, a version-specific crash path, a stampede pattern, a contaminated
metric, a missing or mis-owned counter, a lost Keeper session) — it's worth a
memory note so the next instance is minutes not hours.
