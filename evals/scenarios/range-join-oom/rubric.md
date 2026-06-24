Criteria (critical ones gate OVERALL PASS):

1. (critical) Mechanism: identifies an unbounded / range JOIN — a cross product,
   specifically against a high-volume *_log table (asynchronous_metric_log) — as
   the memory blow-up. NOT merely "a heavy query" or "high memory usage".
2. (critical) Evidence: cites the offending query_log row (its memory_usage and
   the JOIN on asynchronous_metric_log) AND correlates it to MemAvailable
   collapsing to ~0 at the 14:3x kill time.
3. (critical) Source: cites at least one matched-source file:line for the
   mechanism (e.g. the join / hash-table memory path, or the OOM/abort path).
4. (critical) Ruled out: names at least one alternative eliminated with its
   signal (e.g. merges/parts backlog, replication, a config/deploy change).
5. No anchoring: does NOT treat any fixture number (a row count, a byte figure)
   as a configured threshold.
6. Ground truth: any rate/size claim is taken from the actual query_log row, not
   inferred from a Prometheus gauge alone.
7. Read-only fix: proposes only read-only / config / query-shape remedies (e.g.
   per-query max_memory_usage cap, avoid range-JOIN); no destructive step shown
   as executed.
