# Query state — system.* playbook

The inside view. Once Prometheus has localized *where* and *when*, the cluster's
own `system.*` tables tell you *what it was doing* and *who asked*. All queries
run through `scripts/chq.sh` so the resource caps are always applied.

**Discipline for every query here:** put the time filter in the innermost scan,
`LIMIT` exploratory results, never range-JOIN log tables, and reach for the
pre-aggregated `*_log` tables instead of recomputing over raw data. The log
tables (`query_log`, `metric_log`, `trace_log`, `part_log`, `asynchronous_metric_log`)
are enormous; an unfiltered scan is how a debug probe becomes the incident.

A note on availability: some log tables are disabled per-cluster
(`text_log` often is; `metric_log` may be off). Check this **early**, before you
plan a probe around one:
`./chq.sh "SELECT name FROM system.tables WHERE database='system' AND name LIKE '%_log'"`.
When `text_log` is off and you needed a log line to confirm something (a consumer
rebalance, a stall, a specific warning), you simply can't log-confirm it — fall
back to a **source-derived** conclusion (cite the branch/throw in the matched
tree, see `references/source-map.md`) and label it as source-derived, not
log-confirmed, in the writeup. And after an OOM the in-memory buffer of
`metric_log`/`asynchronous_metric_log` is lost (flush thread starved) —
`query_log` usually survived because it flushed earlier. If pre-crash rows are
missing, say so and fall back to OS logs.

## Discover column / ProfileEvent names — never guess them

ProfileEvent, metric, and `*_log` column names are version- and build-specific,
and many you'd expect don't exist (there is **no** Kafka poll-time counter, for
instance — `KafkaConsumerPollTimeMicroseconds` is not a real column). A guessed
name returns a silent empty result that reads exactly like "the value is zero".
List the real names before building any probe on them:

```sql
-- columns that actually exist in this build's metric_log
SELECT name FROM system.columns
WHERE database='system' AND table='metric_log' AND name LIKE 'ProfileEvent_%Kafka%'

-- or the canonical catalogs (cumulative events + live gauges)
SELECT event  FROM system.events  WHERE event  ILIKE '%kafka%'
SELECT metric FROM system.metrics WHERE metric ILIKE '%pool%'
```

Confirm the name exists, then confirm its *meaning* in source (`ProfileEvents.cpp`
/ `CurrentMetrics.cpp`, see `references/source-map.md`) — a name matching your
guess still might not increment where you think.

## Start here: what errors is the server actually raising

```sql
SELECT name, value, last_error_time, last_error_message
FROM system.errors
WHERE value > 0
ORDER BY value DESC
LIMIT 30
```

`system.errors` is cumulative since start but the cheapest possible orientation —
it names the failure class before you go looking. `FILE_DOESNT_EXIST` in the tens
of millions = a dead/corrupt disk, not application error. `TOO_MANY_PARTS` =
merge backlog. `MEMORY_LIMIT_EXCEEDED` = something hit a cap. `CANNOT_SCHEDULE_TASK`
= thread creation failed.

## Finding the culprit query (slow / heavy / OOM)

```sql
SELECT
    query_id, user, type,
    query_duration_ms,
    formatReadableSize(memory_usage)        AS mem,
    formatReadableSize(read_bytes)          AS read,
    result_rows, exception_code, left(query, 200) AS q
FROM system.query_log
WHERE event_time > now() - INTERVAL 15 MINUTE     -- innermost filter
  AND type IN ('QueryFinish','ExceptionWhileProcessing','ExceptionBeforeStart')
ORDER BY memory_usage DESC
LIMIT 20
```

Adjust the window tightly around the incident timestamp from Prometheus. Sort by
`memory_usage` for OOM hunts, `query_duration_ms` for slowness, `read_bytes` for
I/O. Caveat from a real OOM: the biggest *tracked* query may be only a few GiB
while real RSS hit hundreds — untracked allocations (cross-joins) overshoot the
tracker, so a modest top entry doesn't exonerate a query whose *shape* is
dangerous (range-JOIN, huge GROUP BY, `arrayJoin` blowup).

## Per-node latency profile (the disk-straggler proxy)

When Prometheus can't hand you a clean per-node iowait number (see
`references/cluster-state.md` step 3), the latency *shape* per node is the next
best disk-straggler evidence. A node on slow media shows a healthy p50 but a fat
p999 — cache-missing reads pay the slow-disk penalty on the tail:

```sql
SELECT hostName() AS node, count() AS queries,
       quantile(0.50)(query_duration_ms)  AS p50,
       quantile(0.99)(query_duration_ms)  AS p99,
       quantile(0.999)(query_duration_ms) AS p999
FROM clusterAllReplicas(<cluster>, system.query_log)
WHERE event_time > now() - INTERVAL 1 HOUR    -- innermost filter; widen carefully
  AND type = 'QueryFinish'
GROUP BY node
ORDER BY p999 DESC
LIMIT 30
```

This scans `query_log` on every node — classic fan-out. If it trips
`Code: 158`, narrow the window and raise `CH_MAX_ROWS` for that one call (the
fleet-aware recipe in `SKILL.md`). Nodes that cluster at a high p999 while their
p50 sits with the pack are the stragglers; confirm the media with
`node_disk_info` model strings.

## Attribution: who ran it, from where

When you need to name the source of a query:

```sql
SELECT query_id, user, address, interface, os_user, client_name, client_hostname,
       http_user_agent, forwarded_for
FROM system.query_log
WHERE query_id = '...'
LIMIT 1
```

Read the fields together:
- `interface` native vs http; `address=::1` / `127.0.0.1` = **local on the node**
  (someone in a `clickhouse-client` shell), not over the network.
- `client_name='ClickHouse server'` = a **distributed secondary query** from a
  peer shard (routine fan-out), not a human. `client_name='ClickHouse client'`
  + `os_user=root` + local address = a person/script on the box.
- `query_id` shape: a prod gateway often prefixes ids (`gateway_...`); a plain
  UUID is typically ad-hoc/interactive.
- A burst of thousands of `default`-user queries from ~N peer addresses in a few
  minutes is normal shard fan-out, not an attack — concurrency removes headroom
  but rarely *is* the root cause; check summed tracked memory before blaming volume.

**Confirm what you measure isn't also driven by production.** Before you credit a
`part_log` / `query_views_log` / metric number to the thing you're investigating
(a test, a specific job, one consumer group), check the target table or metric
isn't *also* fed by production traffic on the same node — a test consumer group
writing to a prod-shared target table makes its `part_log` rows un-isolable, and
you'll credit the test with production's volume. Find a test-exclusive signal — a
dedicated `_local`/staging table, a distinct `user` or `query_id` prefix, or a
node only the test hits — and measure *that*. If you can't isolate it, say the
number is contaminated rather than reporting it as clean.

## Live queries right now

```sql
SELECT query_id, user, elapsed,
       formatReadableSize(memory_usage) AS mem, left(query,160) AS q
FROM system.processes
ORDER BY memory_usage DESC
LIMIT 20
```

## Parts and the merge pipeline

Part pile-up (`TOO_MANY_PARTS`) and failing-merge storms:

```sql
-- which table/partition is piling up
SELECT database, table, partition_id, count() AS parts, sum(rows) AS rows,
       formatReadableSize(sum(bytes_on_disk)) AS size
FROM system.parts
WHERE active
GROUP BY database, table, partition_id
ORDER BY parts DESC
LIMIT 20
```

```sql
-- are merges failing? (failing-merge storm: launches with errors, ~0 duration)
SELECT event_time, database, table, error, left(exception,200) AS ex,
       duration_ms, rows
FROM system.part_log
WHERE event_time > now() - INTERVAL 30 MINUTE
  AND event_type = 'MergeParts'
  AND error != 0
ORDER BY event_time DESC
LIMIT 30
```

When the pile-up is genuine over-insertion (not a failing-merge storm), the fix
is ingestion-shaped — consult `clickhouse-best-practices`: `insert-batch-size`,
`insert-async-small-batches`, and the `schema-partition-*` rules. Cite the rule
in the writeup.

A partition pinned at exactly `parts_to_throw_insert` (e.g. 3000) for hours, with
`Merge` launches high but `MergesTimeMilliseconds` ~0 and `part_log` showing the
same merge erroring instantly (`FILE_DOESNT_EXIST` on a `.cmrk2`/`.bin`), is a
**failing-merge retry storm** — and the real cause is usually underneath (a dead
disk). Don't `DROP PARTITION` to "fix" it; that's a band-aid that won't hold
while the disk is broken. Verify peers are complete (`system.replicas`) and treat
the hardware.

## Throughput ground truth: part_log rows written

When the question is "how many rows actually moved" — Kafka ingest, MV fan-out,
insert rate — the metric counters lie and the external offset lies harder. The
rows that truly landed are in `part_log`, and this is the **tiebreaker whenever a
metric and a counter disagree** (the ground-truth rule in `SKILL.md`):

```sql
SELECT toStartOfMinute(event_time) AS m, sum(rows) AS rows_written
FROM system.part_log
WHERE event_time > now() - INTERVAL 30 MINUTE
  AND event_type = 'NewPart'
  AND database = '...' AND table = '...'      -- and beware shared targets (see attribution)
GROUP BY m ORDER BY m
```

**Kafka caveat — the background-insert counters undercount.** `metric_log` Kafka
ProfileEvents (`KafkaRowsRead`, etc.) badly undercount the background-insert path
— one incident saw ≈257k reported against 7.26M actually written. Don't rate them
for throughput. Use `part_log` (rows written) for *volume*, and `query_views_log`
for the insert/MV path — it also gives a clean insert-concurrency proof (max
concurrent inserts on the table = number of consumers). For consumer/thread-pool
health, route to `altinity-expert-clickhouse-kafka`.

## Replication health

```sql
SELECT database, table, is_readonly, is_session_expired,
       future_parts, parts_to_check, queue_size, inserts_in_queue,
       merges_in_queue, log_max_index, log_pointer,
       absolute_delay, last_queue_update_exception
FROM system.replicas
WHERE queue_size > 0 OR is_readonly OR absolute_delay > 0
ORDER BY absolute_delay DESC
LIMIT 30
```

`is_readonly=1` = lost its ZooKeeper/Keeper session (can't write). Large
`absolute_delay` / `queue_size` = lag; check `last_queue_update_exception` and
`system.replication_queue` for *why* entries are stuck (fetch failing, merge
failing, missing part). A replica re-fetching parts from healthy peers is the
recovery path after a disk rebuild.

## Thread-pool and FD exhaustion

```sql
-- thread pool headroom (CANNOT_SCHEDULE_TASK territory)
SELECT metric, value FROM system.metrics
WHERE metric IN ('GlobalThread','GlobalThreadActive','LocalThread',
                 'LocalThreadActive','Query','BackgroundMergesAndMutationsPoolTask',
                 'OpenFileForRead','OpenFileForWrite')
```

```sql
-- admission stampede signature, from metric_log around the failure second
SELECT event_time, CurrentMetric_Query, CurrentMetric_GlobalThread,
       ProfileEvent_Query
FROM system.metric_log
WHERE event_time BETWEEN '<t-5s>' AND '<t+5s>'
ORDER BY event_time
```

`CANNOT_SCHEDULE_TASK "failed to start the thread"` with `GlobalThread` far below
its limit is **not** pool saturation — it's the OS transiently refusing `clone()`
under a one-second admission stampede (`CurrentMetric_Query` jumping from single
digits to hundreds in one second). The lever is `max_concurrent_queries` (cap the
stampede), not `max_thread_pool_size`. Confirm against `src/Common/ThreadPool.cpp`
(the catch around the `std::thread` ctor).

FD exhaustion: open part files (`.bin` + `.cmrk2`, ×2 per column per part, and
JSON/Dynamic subcolumns each get their own file pair) accumulate toward the FD
soft limit. `OpenFileForRead` approaching `ulimit -n` → `errno 24` → on a build
with the throwing-destructor bug, a hedged-connections destructor throws during
unwinding → `std::terminate` → SIGSEGV. Mitigations: raise the FD limit,
`use_hedged_requests=0` (turns the crash into a clean per-query error), and cut
part count / tighten TTL / reduce subcolumn fan-out.

## Settings & profiles in effect

```sql
SELECT name, value FROM system.settings
WHERE name IN ('max_memory_usage','max_memory_usage_for_user',
               'max_server_memory_usage','max_concurrent_queries',
               'max_threads','use_hedged_requests','parts_to_throw_insert')
```

A `max_memory_usage = 0` (no per-query cap) on an interactive/default profile is
the precondition that lets one query OOM a node — the single highest-value fix is
usually setting it.

**Pool sizes: trust `system.server_settings`, not `system.settings`.** Server-level
sizing — `background_message_broker_schedule_pool_size`, `background_pool_size`,
`max_thread_pool_size`, `max_concurrent_queries` — lives in `server_settings`; the
same-named row in `system.settings` can carry a *profile* value that disagrees
(one cluster showed pool size 16 in the profile while the server actually ran 32).
For anything that sizes a pool or the server, read `server_settings`:

```sql
SELECT name, value, default, changed
FROM system.server_settings
WHERE name LIKE '%pool_size%' OR name LIKE '%thread%' OR name = 'max_concurrent_queries'
```

**Read config from `system.settings`, not from `query_log.Settings` of your own
probes.** Every query `chq.sh` runs carries the wrapper's safety caps
(`max_threads=4`, `max_memory_usage=...`, `max_rows_to_read=...`, etc.), and those
land in that query's `system.query_log.Settings` map. If you inspect
`query_log.Settings` and read those back as production config, you'll misreport the
cluster's real values — a past memory note wrongly recorded `max_threads=4` that
was only the wrapper's `CH_MAX_THREADS` cap leaking through (production was 10,
unchanged). The query above (`SELECT ... FROM system.settings`) reflects the live
profile and is the correct source. If you must read `query_log.Settings`, scope it
to a **real application `query_id`** (not one this skill issued) before trusting
the numbers.

## ClickHouse SQL gotchas that cost a retry

A few grammar rules bite repeatedly when writing diagnostic SQL — each one is a
wasted round-trip:

- **An alias can't shadow then reuse an aggregate.** `sum(rows) AS rows` and then
  referencing `rows` again in the same scope collides (the identifier now means
  the alias). Alias to a fresh name: `sum(rows) AS rows_written`.
- **No nested aggregates.** `sum(count())` is rejected — push the inner aggregate
  into a subquery and aggregate its result in the outer query.
- **`ANY LEFT JOIN` needs aliased subqueries.** Wrap each side in
  `(SELECT ...) AS l` / `(SELECT ...) AS r` and join on the alias, rather than
  joining bare table expressions.
