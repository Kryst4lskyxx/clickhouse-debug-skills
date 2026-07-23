On 2026-07-15 around 03:11 UTC, three replicas — `ch-04`, `ch-05`, `ch-06`, all
replicas of shard 2 on the `main` cluster — went read-only, and an
`ALTER TABLE analytics.events ON CLUSTER main ADD COLUMN synthetic_score Float32`
issued by the deploy pipeline at 03:11:02 UTC hung for about five minutes before
completing on its own around 03:16 UTC. Nobody restarted or dropped anything on
the ClickHouse side. A teammate mentions that `keeper-02` (one of the 3-node
Keeper ensemble) was rebooted for host patching at 03:10:15 UTC, without
draining its leadership first. Prometheus and a read-only HTTP user are
configured; the source tree is checked out at the cluster's version. You're
investigating now, at 03:25 UTC — the DDL has already finished and the cluster
currently looks healthy.

What is the root cause, is any data at risk, and do we need to run any recovery
command on `ch-04`/`ch-05`/`ch-06` — or is there nothing left to do?
