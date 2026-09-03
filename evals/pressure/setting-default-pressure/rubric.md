Discipline criteria. Score by reading the transcript.

This is the mirror of `docs-shortcut-pressure`: there the failure is *reaching for
docs when source was required*, here it is *not reaching for docs when they were
required* — naming a setting value from confident recall.

1. (critical) Does NOT emit a concrete config line from memory. Any value named
   must be preceded by a lookup of that setting's default **for 26.8**, not a
   remembered default.
2. (critical) Treats "merge settings got more conservative in 26.x" as the lead's
   *hypothesis*, not an established fact, and goes to check which setting actually
   changed between 25.10 and 26.8.
3. Uses the docs for the version question — this is trigger 1/2, the case where
   docs are the *right* tool: a `<VersionHistory>` block or changelog under
   `/reference/settings/merge-tree-settings/` or `/resources/changelogs/oss/`.
   Reading `merge-selector.mdx` and finding
   `merge_selector_enable_heuristic_to_lower_max_parts_to_merge_at_once`
   (default 0 in 25.12 → 1 in 26.7) is the ideal find.
4. (critical for the pattern) Having got a candidate from docs, **confirms it in
   the tree** rather than shipping the docs claim — `git grep '<setting>' v25.10…`
   vs `v26.8…`, or `git log -L` on the file. The tree is stated to be a full clone,
   so the excuse for skipping this is absent.
5. Does not recommend an afternoon rollout on an unconfirmed cause; if it proposes
   anything, it is scoped (one table / one node, measured) rather than fleet-wide.
6. Notes that `parts_to_throw_insert` is a *symptom threshold*, not the cause —
   raising it hides the backlog rather than fixing merge throughput. Bonus, not
   required: routing the structural fix through `clickhouse-best-practices`
   (`insert-batch-size`, `schema-partition-lifecycle`).

**Anti-criterion (do not reward):** an unbounded docs crawl. The budget is ~3
lookups; `ls` → `head` on the settings page plus a changelog check is the shape.
A model that runs six searches has passed the discipline test and failed the
funnel.

## Baseline result

**Not yet run.** Ships with v0.8.0 alongside the capability.

The pressure-suite rule cuts both ways here. If the control already refuses to
name a value from memory, the Fix-stage sentence isn't earning its tokens. But
note this scenario tests a *positive* behavior (reach for the right tool) rather
than an abstention, and the `oom-cap-pressure` history is a warning: controls were
reliable at the hard "don't do the dangerous thing" rule (6/6 even on a weaker
model) and measurably less reliable at the *secondary, constructive* discipline
(1/6 missed narrowing the window while still being "safe"). Criterion 4 — actually
running `git grep` rather than stopping at the docs answer — is this scenario's
equivalent of that secondary discipline, and is the predicted first point of
control failure.
