# Cluster state — Prometheus playbook

The outside view. Prometheus tells you what the OS and the ClickHouse server
expose without you touching the data path. Use it first: it's cheap, it covers
the whole fleet at once, and it tells you whether a problem is one node or
cluster-wide before you drill in.

All queries below assume `scripts/promq.sh` and `export PROM=...`. Substitute the
cluster's actual label scheme (`cluster=`, `instance=`, `pod=`, `namespace=`) —
discover it first if unknown:

```bash
./promq.sh 'group by (cluster) (up)'          # what cluster labels exist
./promq.sh 'up{cluster="example-clickhouse"}'  # then scope to yours
```

**Verify the target is actually scraped by *this* Prometheus before mapping its
labels.** A fleet often runs several Prometheis (per-k8s-cluster, per-DC); the
node you care about can simply be absent from the one you were pointed at, and
no label scheme will conjure it. Confirm it exists here first:

```bash
./promq.sh 'up{instance=~".*<node-or-ip>.*"}'   # any series back = it's scraped here
./promq.sh 'count(up{cluster="..."})'            # sanity: target count for this cluster
```

0 series for a node you *know* is alive means **wrong Prometheus, not a down
node** — go find the Prometheus that scrapes it instead of burning probes mapping
nodename → IP → subnet in the wrong one.

To find a **metric name** when you only know a fragment, match server-side with
a `__name__` regex — don't fetch `/api/v1/label/__name__/values`, which returns
the entire catalog as one multi-hundred-KB line that chokes `jq`:

```bash
./promq.sh 'group by (__name__) ({__name__=~"ClickHouse.*Memory.*"})'  # names only
```

A **guessed metric name that doesn't exist returns 0 series, not an error** — the
classic silent NA that reads like "the value is zero". Metric families vary by
build and by bare-metal-vs-k8s, so discover the real name before trusting a probe.
`promq.sh` now prints a `0 series — may not exist here` warning instead of an empty
table, but the discipline is the same: confirm the name, don't assume it.

There are two metric families:
- **`node_*`** — node_exporter (the host OS). Present on bare metal; on k8s you
  instead lean on `container_*` (cadvisor) and `kube_*` (kube-state-metrics).
- **`ClickHouse*`** — the server's own metrics endpoint (`:9363` typically),
  mirroring `system.metric_log`: `ClickHouseProfileEvents_*` (counters, rate
  them), `ClickHouseMetrics_*` (gauges), `ClickHouseAsyncMetrics_*` (sampled).

## Step 1 — Up-ness and what kind of "down"

```bash
./promq.sh 'up{cluster="..."} < 1'                       # which targets are down
./promq.sh 'up{cluster="..."}' range 6h 300s             # flapping vs hard-down
./promq.sh 'ClickHouseAsyncMetrics_Uptime{cluster="..."}'  # low/reset = recent restart
```

A target down with `Uptime` resetting to seconds = the **server crashed and
restarted**, not a host reboot. Distinguish:
- Both node_exporter (`:9100`) and clickhouse (`:9363`) scrapes blip together,
  but host `uptime` is unchanged → **host memory stall / OOM**, not a reboot.
- Only `:9363` down, host fine → clickhouse-server process died (crash, OOMKilled
  on k8s, manual stop).
- Host `node_time_seconds - node_boot_time_seconds` (uptime) actually small →
  real host reboot.

## Step 2 — OOM (the most common "node fell over")

```bash
./promq.sh 'node_memory_MemAvailable_bytes{cluster="..."}' range 1h 60s
./promq.sh 'increase(node_vmstat_oom_kill{cluster="..."}[1h])'   # >0 = OS OOM killed something
./promq.sh 'ClickHouseAsyncMetrics_CGroupMemoryUsed{cluster="..."}'
```

Signature of a query-driven OOM: `MemAvailable` collapses sharply (a large
fraction of RAM gone fast), then `node_vmstat_oom_kill` steps +1, then `Uptime`
resets (observed once: hundreds of GB to single-digit GB within a minute). The gap between `max_server_memory_usage` and total RAM is the
headroom a fast/untracked spike has to blow through — small headroom + no
per-query `max_memory_usage` cap is the classic setup. Next step: query
`system.query_log` for the culprit (query-state reference).

## Step 3 — CPU, iowait, load

### Per-node iowait (the disk-straggler discriminator)

iowait is the highest-value CPU signal for this skill — disk-straggler incidents
are exactly its wheelhouse — but it's easy to get a silent NA. Use the
**`node_exporter` CPU counter as a per-core fraction**, which is comparable across
nodes regardless of core count, and is the recipe that actually works on bare metal:

```bash
# fraction of CPU time in iowait, per node (0..1). avg by, NOT sum by:
# sum scales with core count and isn't comparable between heterogeneous nodes.
./promq.sh 'avg by (instance) (rate(node_cpu_seconds_total{cluster="...",mode="iowait"}[5m]))'
./promq.sh 'avg by (instance) (rate(node_cpu_seconds_total{cluster="...",mode="iowait"}[5m]))' range 6h 300s
# total busy fraction (everything but idle), per node:
./promq.sh 'avg by (instance) (rate(node_cpu_seconds_total{cluster="...",mode!="idle"}[5m]))'
```

**Signals that don't discriminate (don't waste a round-trip):**
- **`ClickHouseProfileEvents_OSIOWaitMicroseconds` (rate) often returns nothing**
  on a given cluster — the server-side OS metrics may be disabled or named
  differently. If it's empty, that's a missing metric, not zero iowait; fall back
  to the `node_cpu_seconds_total` recipe above. (`promq.sh` now warns on 0 series.)
- **`node_load5` / `LoadAverage1` rarely separates the tiers** — CPU load is
  usually similar across nodes even when one is disk-bound. Use it to confirm a
  node is busy, not to find the straggler.

One node with iowait persistently and markedly higher than its peers, stable for
hours, is rarely workload — suspect **hardware tier mismatch** (observed once:
~10x peer iowait). Confirm with disk metrics (step 4). When no
direct iowait number separates the tiers, the **query latency profile is the
proxy**: a disk-straggler node shows a healthy p50 but a fat p999 (reads that miss
page cache hit the slow device). See the per-node latency query in
`references/query-state.md`.

High CPU with **0 user queries** on the node points at background work — a
failing-merge retry storm spins CPU re-acquiring the Context lock. Cross-check
`ClickHouseProfileEvents_ContextLock` rate against query rate (query-state ref).

## Step 4 — Disk (incl. the SATA-vs-NVMe trap)

```bash
./promq.sh 'node_disk_info{cluster="..."}'   # model/revision labels -> SATA vs NVMe
./promq.sh 'sum by (instance,device) (rate(node_disk_io_time_seconds_total{cluster="..."}[5m]))'        # util
./promq.sh 'sum by (instance,device) (rate(node_disk_io_time_weighted_seconds_total{cluster="..."}[5m]))' # queue depth
./promq.sh 'sum by (instance,device) (rate(node_disk_written_bytes_total{cluster="..."}[5m]))'
./promq.sh 'sum by (instance,device) (rate(node_disk_writes_completed_total{cluster="..."}[5m]))'
```

**Collapsing per-device metrics to one number per node.** Disk metrics are
per-device (`device="nvme0n1"`, `sda`, `dm-0`, …), which is noisy and hard to map
back to a node — a host has several devices and only one carries the data. Take
the **busiest device per node** so each node gets a single comparable value:

```bash
# per-node disk busy = the hottest device on that host (util, 0..1)
./promq.sh 'max by (instance) (rate(node_disk_io_time_seconds_total{cluster="..."}[5m]))'
# per-node queue depth = hottest device
./promq.sh 'max by (instance) (rate(node_disk_io_time_weighted_seconds_total{cluster="..."}[5m]))'
# average read latency per device (seconds): time / completed ops; filter to the data device
./promq.sh 'rate(node_disk_read_time_seconds_total{cluster="..."}[5m]) / rate(node_disk_reads_completed_total{cluster="..."}[5m])'
```

`max by (instance)` is the right reducer here (the data device is the slow one
under load); `sum by` would dilute it across idle boot/log disks.

Within one cluster, nodes can sit on different storage media. A node doing *less*
write work but showing *more* util / higher queue depth / higher write latency
than peers is on slower media (observed once: a SATA SSD among NVMe peers).
`node_disk_info` model strings are the proof. Note which device actually carries
the data — a host may boot off one tier but write data to another; what matters is
the device under load.

**When the disk metrics themselves don't separate the tiers** (per-device labels
won't map cleanly, or the cluster doesn't export `node_disk_*`), fall back to the
**latency-profile proxy**: SATA-tier nodes show a normal p50 but a fat p999
(cache-missing reads pay the slow-media penalty), while NVMe peers stay tight at
p999. That per-node latency split (computed from `query_log` in
`references/query-state.md`) is often the cleanest disk-straggler evidence you can
get without a direct iowait number.

Disk reads near zero everywhere is normal (recent data served from page cache);
ClickHouse disk pressure is almost all writes (inserts + merges).

A disk that has *died* shows up as the OS losing the filesystem: pair this with
the inside view — `system.errors` full of `FILE_DOESNT_EXIST` / `PATH_ACCESS_DENIED`,
`dmesg` showing `no available path - failing I/O` and `EXT4-fs` bitmap errors,
and `df` grossly under-reporting usage on a full disk (= bitmap corruption;
observed once: 1% used on a full disk).

## Step 5 — Network (distributed query / replication)

```bash
./promq.sh 'sum by (instance) (rate(node_network_receive_bytes_total{cluster="..."}[5m]))'
./promq.sh 'ClickHouseMetrics_DistributedSend{cluster="..."}'
./promq.sh 'ClickHouseProfileEvents_DistributedConnectionFailTry{cluster="..."}' 
```

## Step 6 — ClickHouse server metrics worth knowing

Counters (wrap in `rate(...[Nm])`):
- `ClickHouseProfileEvents_Query`, `_SelectQuery`, `_InsertQuery` — traffic. Zero
  on a busy-looking node ⇒ the load is background, not user queries.
- `ClickHouseProfileEvents_ContextLock` + `_ContextLockWaitMicroseconds` — high
  count with ~0 wait = CPU spin (failing-merge storm); high wait = real contention.
- `ClickHouseProfileEvents_Merge` vs `_MergesTimeMilliseconds` — many merge
  launches with ~0 time = merges aborting instantly and retrying (storm).
- `ClickHouseProfileEvents_FailedQuery`, `_QueryMemoryLimitExceeded`.

Gauges:
- `ClickHouseMetrics_Query` — concurrent queries in flight.
- `ClickHouseMetrics_BackgroundMergesAndMutationsPoolTask` — merge backlog.
- `ClickHouseAsyncMetrics_MaxPartCountForPartition` — pinned at the cluster's
  `parts_to_throw_insert` value (a per-cluster default; confirm it via
  `system.server_settings`) → TOO_MANY_PARTS imminent (observed values once: 300
  and 3000).
- `ClickHouseMetrics_ReadonlyReplica` — replicas currently read-only (lost Keeper
  session). `ClickHouseAsyncMetrics_ReplicasMaxQueueSize` / `_ReplicasMaxAbsoluteDelay`
  — replication backlog / lag (these are **async** metrics, not `ClickHouseMetrics_`;
  `ReplicasMax*` live in `ServerAsynchronousMetrics`). For a Keeper / read-only
  incident, see `references/keeper-state.md` (Outside section).
- `ClickHouseMetrics_GlobalThread`, `_GlobalThreadActive` vs the pool limit, and
  `ClickHouseMetrics_OpenFileForRead` vs the FD limit — exhaustion approaching.

**A metric name usually lives in exactly one family — don't assume one table holds
everything.** Load/CPU async-sample under `ClickHouseAsyncMetrics_*`, but pool
gauges like `BackgroundMessageBrokerSchedulePoolTask`/`...Size` are
`ClickHouseMetrics_*` (CurrentMetric gauges, the `metric_log.CurrentMetric_*`
columns), **not** async. 0 series in one family ≠ the value is absent — try the
other family, and confirm which one owns it in source (`CurrentMetrics.cpp` vs
`AsynchronousMetrics.cpp`, see source-map).

## Bare metal vs Kubernetes

**Bare metal** — `node_*` metrics are authoritative. For host-level forensics
(disk death, who logged in, OOM details) the evidence lives in `dmesg`, `df -h`,
`last`, `journalctl`, `/var/log/`, `/root/.bash_history`. You usually can't run
these yourself — name them as the operator's next step.

**Kubernetes** — a "down node" is usually a **pod** crash-looping. Shift to:

```bash
./promq.sh 'kube_pod_container_status_restarts_total{namespace="...",pod=~"...ch.*"}'
./promq.sh 'kube_pod_container_status_last_terminated_reason{namespace="..."}'   # OOMKilled / Error
./promq.sh 'rate(container_cpu_usage_seconds_total{namespace="...",pod=~"...ch.*"}[5m])'
./promq.sh 'container_memory_working_set_bytes{namespace="...",pod=~"...ch.*"}'
./promq.sh 'kube_pod_container_resource_limits{namespace="...",resource="memory"}'
```

Exit codes: **137** = SIGKILL (usually OOMKilled — check
`last_terminated_reason`); **139** = SIGSEGV (a real crash inside the server —
go find the throw/abort path in source, e.g. a throwing destructor). Restart
count climbing on one shard but not others is a time-bomb correlated with that
shard's age/data volume (e.g. FD exhaustion that scales with accumulated parts).
For pods, the cgroup memory **limit** is the OOM ceiling, not host RAM — compare
`container_memory_working_set_bytes` to `kube_pod_container_resource_limits`.

Operator-side k8s forensics to recommend: `kubectl describe pod` (events, last
state, reason), `kubectl logs -p` (previous container), `kubectl get events`.
