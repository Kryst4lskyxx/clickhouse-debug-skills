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
./promq.sh 'up{cluster="OLAP-FOO-ClickHouse"}'  # then scope to yours
```

To find a **metric name** when you only know a fragment, match server-side with
a `__name__` regex — don't fetch `/api/v1/label/__name__/values`, which returns
the entire catalog as one multi-hundred-KB line that chokes `jq`:

```bash
./promq.sh 'group by (__name__) ({__name__=~"ClickHouse.*Memory.*"})'  # names only
```

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

Signature of a query-driven OOM: `MemAvailable` collapses from hundreds of GB to
single-digit GB within a minute, then `node_vmstat_oom_kill` steps +1, then
`Uptime` resets. The gap between `max_server_memory_usage` and total RAM is the
headroom a fast/untracked spike has to blow through — small headroom + no
per-query `max_memory_usage` cap is the classic setup. Next step: query
`system.query_log` for the culprit (query-state reference).

## Step 3 — CPU, iowait, load

```bash
./promq.sh 'sum by (instance) (rate(node_cpu_seconds_total{cluster="...",mode="iowait"}[5m]))' 
./promq.sh 'sum by (instance) (rate(node_cpu_seconds_total{cluster="...",mode!="idle"}[5m]))'
./promq.sh 'node_load5{cluster="..."}'
```

One node with ~10x the iowait of its peers, stable for hours, is rarely workload
— suspect **hardware tier mismatch**. Confirm with disk metrics (step 4).

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

Within one cluster, nodes can have different drives. A node doing *less* write
work but showing *more* util / higher queue depth / higher write latency than
peers is on slower media (SATA SSD vs NVMe). `node_disk_info` model strings are
the proof. Note which device actually carries the data — many hosts boot off SATA
but write data to NVMe; what matters is the device under load.

Disk reads near zero everywhere is normal (recent data served from page cache);
ClickHouse disk pressure is almost all writes (inserts + merges).

A disk that has *died* shows up as the OS losing the filesystem: pair this with
the inside view — `system.errors` full of `FILE_DOESNT_EXIST` / `PATH_ACCESS_DENIED`,
`dmesg` showing `no available path - failing I/O` and `EXT4-fs` bitmap errors,
and `df` reporting phantom-empty (1% used on a full disk = bitmap corruption).

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
- `ClickHouseAsyncMetrics_MaxPartCountForPartition` — pinned at a round number
  (e.g. 300/3000) = at the `parts_to_throw_insert` cap → TOO_MANY_PARTS imminent.
- `ClickHouseMetrics_ReplicasMaxQueueSize`, `_ReadonlyReplica` — replication health.
- `ClickHouseMetrics_GlobalThread`, `_GlobalThreadActive` vs the pool limit, and
  `ClickHouseMetrics_OpenFileForRead` vs the FD limit — exhaustion approaching.

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
