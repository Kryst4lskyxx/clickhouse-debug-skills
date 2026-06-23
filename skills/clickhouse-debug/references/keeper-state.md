# Keeper / ZooKeeper & read-only replicas — playbook

A cross-cutting playbook (not a single stage). A Keeper incident shows up in all
three views at once: Prometheus says replicas went read-only, `system.*` says
which sessions expired, and the source says *why* read-only is the server's
correct response. Reach for this file when the symptom is replicas stuck
**read-only**, **`KEEPER_EXCEPTION`** storms, hanging **`ON CLUSTER`** DDL,
replication stalled "on Keeper", or anything **after a Keeper/ZooKeeper restart**.

**The core mechanism (always true).** A `ReplicatedMergeTree` table needs a live
ClickHouse Keeper (ZooKeeper) session to accept writes. When that session is lost
or expires, the table flips to **read-only** and the restarting thread keeps
retrying to re-initialize — and it **clears read-only on its own** once the
session is healthy again. So read-only is usually a *symptom of Keeper*, not of
the table: **fix Keeper quorum first and most replicas self-heal.** Confirm the
mechanism in `src/Storages/MergeTree/ReplicatedMergeTreeRestartingThread.cpp`
(`setReadonly()` / `partialShutdown()`; it un-sets read-only when
`!storage.getZooKeeper()->expired()`).

All SQL runs through `scripts/chq.sh` (caps applied). On a proxy-fronted fleet wrap
each `system.*` table in `clusterAllReplicas(<cluster>, …)` and select `hostName()`
so you know which node each row came from — a Keeper incident is almost always
"a *subset* of nodes/replicas", and the per-node spread is the whole point.

## Orient — the Keeper error family in `system.errors`

```sql
SELECT name, value, last_error_time, left(last_error_message, 160) AS msg
FROM clusterAllReplicas(<cluster>, system.errors)
WHERE name IN ('KEEPER_EXCEPTION','TABLE_IS_READ_ONLY','NO_ZOOKEEPER',
               'ALL_CONNECTION_TRIES_FAILED','NOT_A_LEADER','NO_ACTIVE_REPLICAS')
  AND value > 0
ORDER BY value DESC
LIMIT 50
```

What each names (numbers from `src/Common/ErrorCodes.cpp`, this tree's version):
- `KEEPER_EXCEPTION` (999) — the catch-all for a failed Keeper operation; the
  *message* carries the real Coordination code (connection loss, session expiry…).
- `TABLE_IS_READ_ONLY` (242) — a write hit a replica that lost its session.
- `NO_ZOOKEEPER` (225) — Keeper not configured/available at all.
- `ALL_CONNECTION_TRIES_FAILED` (279) — couldn't reach any Keeper host.
- `NOT_A_LEADER` (529), `NO_ACTIVE_REPLICAS` (254) — quorum/leadership trouble.

**Trap — `SESSION_EXPIRED` is not a ClickHouse error code.** Session expiry is
`Coordination::Error::ZSESSIONEXPIRED = -112` (`src/Common/ZooKeeper/IKeeper.h`,
`IKeeper.cpp`), surfaced *through* `KEEPER_EXCEPTION`. Grepping `ErrorCodes.cpp`
for `SESSION_EXPIRED` returns nothing — don't build a probe around a name that
doesn't exist (the skill's "never guess names" rule; see `references/query-state.md`).

## Inside — who lost their session

**The headline probe: which replicas are read-only and why.** `is_session_expired`
is documented as "basically the same as `is_readonly`"; `zookeeper_exception` is
the last error fetching info from Keeper.

```sql
SELECT hostName() AS node, database, table,
       is_readonly, is_session_expired,
       total_replicas, active_replicas,          -- active_replicas = those WITH a Keeper session
       queue_size, absolute_delay,
       left(last_queue_update_exception, 120) AS queue_ex,
       left(zookeeper_exception, 120)        AS zk_ex
FROM clusterAllReplicas(<cluster>, system.replicas)
WHERE is_readonly OR is_session_expired OR zookeeper_exception != ''
ORDER BY node, database, table
LIMIT 100
```

`active_replicas < total_replicas` for a table = that many replicas have **no**
Keeper session right now. A read-only *subset* concentrated on certain nodes
points at those nodes' Keeper connectivity, not the table.

**Is each node's session actually alive?** `system.zookeeper_connection` is the
per-node session truth — `is_expired`, how long the session has held, and the
configured timeout:

```sql
SELECT hostName() AS node, name, host, is_expired,
       session_uptime_elapsed_seconds, session_timeout_ms
FROM clusterAllReplicas(<cluster>, system.zookeeper_connection)
ORDER BY is_expired DESC, session_uptime_elapsed_seconds ASC
LIMIT 100
```

A cluster of low `session_uptime_elapsed_seconds` across many nodes = sessions
recently re-established (the Keeper restart). `is_expired=1` = still down. There
should be **one** session per node (`ClickHouseMetrics_ZooKeeperSession` ~1).

**Why replication-queue entries are stuck** (lag that won't drain):

```sql
SELECT hostName() AS node, database, table, type,
       num_tries, num_postponed, left(postpone_reason, 100) AS postpone,
       left(last_exception, 160) AS last_ex
FROM clusterAllReplicas(<cluster>, system.replication_queue)
WHERE num_tries > 0 OR postpone_reason != ''
ORDER BY num_tries DESC
LIMIT 50
```

High `num_tries` with a Keeper-flavored `last_exception` = entries can't commit
against Keeper; this drains itself once sessions recover. (A *non*-Keeper
`last_exception` — fetch/merge failing, missing part — is a different problem;
see `references/query-state.md` replication section.)

**Hanging `ON CLUSTER` DDL.** A DDL waits for every replica to ack in Keeper, so
read-only replicas stall the whole statement:

```sql
SELECT hostName() AS node, entry, cluster, host, status,
       exception_code, left(exception_text, 160) AS ex, left(query, 120) AS q
FROM clusterAllReplicas(<cluster>, system.distributed_ddl_queue)
WHERE status != 'Finished'
ORDER BY entry DESC
LIMIT 50
```

Entries pinned at `Active`/`InProgress` on the same nodes that show read-only
confirms the hang is the *same* root cause, not a separate DDL bug.

## The znode view — `system.zookeeper` (use sparingly)

`system.zookeeper` reads Keeper's tree directly, but **it requires a `path`
predicate** (`WHERE path = '…'` or `path IN (…)`) — a query without one is
rejected, by design. Never try to "list everything"; target a known path (a
table's replicas/log, or the DDL queue) and read one level:

```sql
SELECT name, numChildren, dataLength, mzxid
FROM system.zookeeper
WHERE path = '/clickhouse/task_queue/ddl'   -- DDL queue depth; many children = backlog
ORDER BY name DESC
LIMIT 50
```

This is a direct Keeper read — keep it shallow and `LIMIT`ed; recursing a busy
tree is how a diagnostic probe adds load to an already-struggling Keeper.

## Outside — Keeper / replication in Prometheus

```bash
./promq.sh 'ClickHouseMetrics_ReadonlyReplica{cluster="..."}'                 # >0 = read-only replicas (headline)
./promq.sh 'ClickHouseMetrics_ZooKeeperSession{cluster="..."}'                # should be ~1 per node; 0 = no session
./promq.sh 'rate(ClickHouseProfileEvents_ZooKeeperHardwareExceptions{cluster="..."}[5m])'  # network/connection loss
./promq.sh 'ClickHouseAsyncMetrics_ReplicasMaxQueueSize{cluster="..."}'       # replication backlog (ASYNC family)
./promq.sh 'ClickHouseAsyncMetrics_ReplicasMaxAbsoluteDelay{cluster="..."}'   # lag in seconds (ASYNC family)
```

`ReadonlyReplica` and `ZooKeeperSession` are **CurrentMetrics** (`ClickHouseMetrics_`);
`ReplicasMaxQueueSize` / `_ReplicasMaxAbsoluteDelay` are **async** metrics
(`ClickHouseAsyncMetrics_`, from `src/Interpreters/ServerAsynchronousMetrics.cpp`) —
a name lives in exactly one family, so 0 series under the wrong prefix means wrong
prefix, not "zero" (see the metric-family note in `references/cluster-state.md`).
`ZooKeeperHardwareExceptions` is a **ProfileEvents** counter — rate it.

**Keeper's own health (operator-side).** ClickHouse's `system.*` tells you the
*client* view; the Keeper ensemble's own state needs its four-letter-word
interface (must be enabled via `keeper_server.four_letter_word_white_list`) or its
Prometheus endpoint. Recommend to the operator:

```bash
echo mntr | nc <keeper-host> 9181    # zk_server_state (leader/follower), zk_followers, zk_synced_followers, zk_outstanding_requests
echo ruok | nc <keeper-host> 9181    # "imok" if up
```

No leader, or `zk_synced_followers` below quorum, means the ensemble itself hasn't
recovered — no amount of replica poking fixes that until quorum is back.

## Confirm — source anchors (this tree)

- **Read-only mechanism** → `src/Storages/MergeTree/ReplicatedMergeTreeRestartingThread.cpp`
  (`setReadonly()`, `partialShutdown()`, the re-init loop that clears read-only when
  the session is no longer expired). This is why "wait for Keeper, replicas
  self-heal" is correct and `DROP`/recreate is wrong.
- **Session-expiry code** → `src/Common/ZooKeeper/IKeeper.h` (`ZSESSIONEXPIRED = -112`),
  `IKeeper.cpp` (the code→message map) — confirms the message you see under
  `KEEPER_EXCEPTION`.
- **Column meanings** → `src/Storages/System/StorageSystemReplicas.cpp`,
  `StorageSystemZooKeeperConnection.cpp` (e.g. `is_session_expired` "basically the
  same as `is_readonly`", `active_replicas` = replicas with a Keeper session).

See `references/source-map.md` for the grep patterns and the version-match check.

## Recovery ladder (recommend to the operator — these are writes)

This skill is read-only by construction; the fixes below mutate the cluster, so
**name them as operator actions, don't run them from a probe.** In order:

1. **Restore Keeper quorum first.** If the ensemble lost quorum, that's the fix —
   replicas re-init themselves once sessions re-establish (the restarting thread).
   Verify with `mntr` (leader + synced followers) before touching any replica.
2. **A replica still read-only after quorum is back:** `SYSTEM RESTART REPLICA
   db.table` re-initializes it from Keeper (`InterpreterSystemQuery.cpp`).
3. **The replica's metadata in Keeper is lost/corrupt** (its znode is gone):
   `SYSTEM RESTORE REPLICA db.table` → `restoreMetadataInZooKeeper`. This is the
   lost-metadata case, distinct from a merely-expired session.
4. **Confirm catch-up:** `SYSTEM SYNC REPLICA db.table` waits for the queue to drain.

Do **not** `DROP`/recreate the table or `DROP PARTITION` to "clear" read-only — the
data is intact on healthy peers and the replica recovers through Keeper.

## Kubernetes note

A "crash-looping" Keeper-dependent pod is often **not** crashing: a liveness probe
SIGKILLs (exit **137**) a pod that is up but can't reach Keeper, which reads as a
restart loop. Distinguish from a real SIGSEGV (**139**) — see the exit-code fork in
`references/cluster-state.md`. The cure is Keeper reachability, not restarting the
pod harder.
