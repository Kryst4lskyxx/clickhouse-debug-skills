Criteria (critical ones gate OVERALL PASS):

1. (critical) Mechanism: identifies Keeper session expiry on ch-04/ch-05/ch-06 —
   triggered by the keeper-02 leader reboot/quorum wobble — as why those
   replicas flipped read-only. NOT table/data corruption, NOT a ClickHouse bug.
2. (critical) Evidence: cites `system.errors` showing KEEPER_EXCEPTION and/or
   TABLE_IS_READ_ONLY with a session-expired message, AND
   `system.zookeeper_connection` showing short `session_uptime_elapsed_seconds`
   on ch-04/ch-05/ch-06 versus long uptime on the other nodes — establishing
   WHICH nodes were affected and WHEN they reconnected (~03:16).
3. (critical) Does NOT conclude "nothing happened" or stop investigating from an
   empty/healthy `system.replicas` snapshot alone. `system.replicas` is live
   state that already self-cleared by 03:25; the historical evidence has to come
   from `system.errors` (cumulative counters) and `system.zookeeper_connection`
   (session uptime), not from re-running the same live-state probe.
4. (critical) Cross-validates the outside and inside views rather than trusting
   either alone: the Prometheus `ClickHouseMetrics_ReadonlyReplica` spike
   confirms the *blast radius* (exactly 3 replicas, not more), and the
   `system.errors` / `system.zookeeper_connection` timestamps establish *when*
   (~03:11 expiry, ~03:16 recovery) and *which nodes*. Both must be used; the
   window's exact duration does not need to be independently re-derived from
   Prometheus alone as long as the two views corroborate each other on scope
   and timing rather than either being taken on faith by itself.
5. (critical) Source: cites the read-only self-clearing mechanism in
   `ReplicatedMergeTreeRestartingThread.cpp` (`setReadonly()` / the restarting
   thread's re-init loop that clears read-only once the session is no longer
   expired) as why this recovered without operator action.
6. (critical) Recovery guidance: says NO destructive/recovery command is
   required — replicas already self-healed and the DDL completed. Does NOT
   propose `SYSTEM RESTORE REPLICA`, `SYSTEM RESTART REPLICA`, or a
   DROP/recreate as something that still needs to run. (Mentioning the ladder
   as available *if* a replica were still stuck is fine; requiring it here is
   not.)
7. Trap: does not grep `ErrorCodes.cpp` for a literal `SESSION_EXPIRED` code and
   report confusion at finding nothing — correctly treats session expiry as
   `Coordination::Error::ZSESSIONEXPIRED`, surfaced through `KEEPER_EXCEPTION`.
8. Ruled out: names at least one alternative eliminated with its signal (e.g. no
   deploy/schema change to the table itself, no genuine metadata loss, not a
   merge/replication backlog).
9. No anchoring: does not treat a fixture number (an error counter value, a
   session-uptime figure) as a configured threshold or alerting rule.
