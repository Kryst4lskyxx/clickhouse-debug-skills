# Documentation lookup — retrieval mechanics

The *doctrine* (precedence, the five triggers, sanitization) lives in `SKILL.md`.
This file is the *mechanics*: where things are, how retrieval fails silently, and
the two worked patterns worth memorizing.

One line of doctrine repeated here because everything below depends on it:
**docs narrow the search, source closes the claim.** A docs page is never the
citation under a `## Root cause` sentence.

## The four retrieval rules

The ClickHouse-docs MCP is a virtualized read-only filesystem plus a search tool.
It fails in ways that look like *absence of evidence* rather than errors, so these
rules are about not being lied to by a zero-result.

### 1. Never search or `rg` at bare `/`

Roughly half the tree is translated mirrors — `/ar/`, `/es/`, `/fr/`, `/ja/`,
`/ko/`, `/pt-br/`, `/pt-BR/`, `/ru/`, `/zh/` — each a full copy of the docs.
An unscoped search spends most of its result window on languages you didn't ask
for, and **`-g '!...'` glob excludes are not honored**, so you cannot filter them
out after the fact. Scope the path instead:

```
rg -l "replicated_fetches" /reference /concepts /guides /resources
```

### 2. Prefer structure over search

A `search` call costs ~2.5–3k tokens; a full `system.*` page is 3–6k. Structural
calls (`ls`, `wc -l`, `tree -L 2`) cost 50–800. When you already know roughly
where a thing lives — and for `system.*` tables and settings you always do — walk
to it rather than searching for it:

```
ls /reference/system-tables/ | grep replic      # locate
wc -l /reference/system-tables/replicas.mdx     # size it before paying for it
head -80 /reference/system-tables/replicas.mdx  # read only what you need
```

`head` accepts several paths in one call, which is the cheapest way to compare
two tables' columns.

### 3. A directory-recursive `rg` cannot see MDX components — never trust its zero

This is the one that will burn you, because the thing it hides is the main reason
to be here. Recursive grep over a *directory* searches a stripped prose index;
grep against an *explicit file path* returns the raw page. Verified against the
live tree:

```
rg -l "VersionHistory" /reference/settings/merge-tree-settings
   -> (no output, exit 1)                      # 0 files. This is a LIE.

rg -c "VersionHistory" /reference/settings/merge-tree-settings/merge-selector.mdx
   -> 3                                        # same string, same tree
```

`<VersionHistory>`, `<SettingsInfoBlock>` and every other MDX component are
invisible to the recursive form. **A zero-result from a recursive `rg` means
"unknown", never "absent."** Narrow with `ls`, then grep explicit paths.

### 4. Never search by bare error-code name

`search("CANNOT_SCHEDULE_TASK ...")` degrades into Cloud REST API noise — ~3k
tokens, zero signal. There is **no error-code catalog** in the docs. A handful of
codes have knowledge-base pages (`TOO_MANY_PARTS`, `MEMORY_LIMIT_EXCEEDED`);
`KEEPER_EXCEPTION` and `CANNOT_SCHEDULE_TASK` have nothing, which is why
`routing.tsv` marks them `docs: none — source-confirm only`.

An error code is a **source-tree question**. `grep -rn "CANNOT_SCHEDULE_TASK" src/`
in the matched tree answers it; the docs cannot. Run `./route.sh <CODE>` first —
it tells you whether a docs page exists before you spend a search finding out.

## Worked pattern A — a default changed under us (docs point, git proves)

The highest-value lookup this skill has, because your source tree holds exactly
*one* version and therefore cannot, by itself, tell you what the previous release
did. Docs supply the pointer; git supplies the proof.

**Symptom:** merge behavior changed after an upgrade; parts are accumulating
differently than they did last month.

**Step 1 — docs name the suspect and the release.** Settings pages are chunked by
name prefix, not one-file-per-setting, so `ls` then read:

```
ls /reference/settings/merge-tree-settings/ | grep merge-selector
rg -B8 -A2 "VersionHistory" /reference/settings/merge-tree-settings/merge-selector.mdx
```

which yields, verbatim from the tree (the nesting matters — this is the shape you
are grepping for):

```
<h2 id="merge_selector_enable_heuristic_to_lower_max_parts_to_merge_at_once">
<SettingsInfoBlock type="Bool" default_value="1" />
<VersionHistory rows={[{"id": "row-1","items": [{"label": "26.7"},{"label": "1"},{"label": "Enable by default"}]}, {"id": "row-2","items": [{"label": "25.12"},{"label": "0"},{"label": "New setting"}]}]} />
```

Each `items` array reads *[release, new default, what changed]*. So: introduced in
25.12 defaulting to `0`, flipped to `1` by default in 26.7. That is a hypothesis
with a release attached — **not yet a finding.**

**Step 2 — git closes it in the matched tree.** A full ClickHouse clone carries
every release tag, so both sides of the change are already on disk. Tag naming
varies by release, so list before you reach:

```bash
# Real tags look like v25.3.1.2703-lts / v24.8.14.39-lts — the build and suffix
# differ per release, so never hand-type one. List, then substitute.
git tag --list 'v25.12*' 'v26.7*' | head

SETTING=merge_selector_enable_heuristic_to_lower_max_parts_to_merge_at_once
OLD=$(git tag --list 'v25.12*' | head -1)
NEW=$(git tag --list 'v26.7*'  | head -1)
git grep -n "$SETTING" "$OLD" -- src/Storages/MergeTree/
git grep -n "$SETTING" "$NEW" -- src/Storages/MergeTree/
```

(`git grep <rev>` beats `git show <rev>:<path>` here — merge-tree settings have
moved between `MergeTreeSettings.h` and `MergeTreeSettings.cpp` across releases,
and `git grep` doesn't require you to know which one this version uses. For the
full history of one line, `git log -L` on the file that `git grep` found.)

Now the writeup can say *the default flipped 0→1 in 26.7*, cite `file:line` in
both revisions, and it is a **source-confirmed** claim.

**If the tree is a shallow clone or a tarball** (`git tag --list` empty,
`git rev-parse <tag>` fails), step 2 is unavailable. Say so, keep the docs claim,
and tag it `[docs — not source-confirmed]` in the Evidence block. A labelled soft
claim is fine; an unlabelled one is the failure mode this whole file exists to
prevent.

## Worked pattern B — a `system.*` column you're about to conclude from

`query-state.md` covers the incident-critical columns with source confirmation.
When a conclusion rests on a column it doesn't cover, the docs are the fastest
honest answer — 174 pages under `/reference/system-tables/`, and none of the 31
`clickhouse-best-practices` rules mention a `system.` table at all.

```
head -80 /reference/system-tables/parts.mdx
```

Useful things that live only here: the part-name grammar
(`<partition_id>_<min_block>_<max_block>_<level>_<data_version>`), and the
mutual exclusivity of `primary_key_bytes_in_memory` vs `PrimaryIndexCacheBytes`.

The qualifier matters: look up a column you are about to **base a conclusion on**,
not a column you are merely curious about. Curiosity is how a 3-lookup budget
becomes twelve.

## Where things are

| You need | Path |
|---|---|
| `system.*` column semantics (174 pages) | `/reference/system-tables/<table>.mdx` |
| Keeper / ZooKeeper system tables | `/reference/system-tables/{keeper_*,zookeeper_*}.mdx` |
| Merge-tree settings + defaults + `<VersionHistory>` | `/reference/settings/merge-tree-settings/` (chunked by name prefix) |
| Server settings | `/reference/settings/server-settings/settings/` |
| Keeper operations (config, RAFT, ACLs, converter) | `/guides/oss/deployment-and-scaling/keeper/index.mdx` (~1,550 lines — `head` it) |
| Prometheus ↔ `system.*` metric mapping | `/resources/support-center/knowledge-base/monitoring-debugging/mapping-of-system-metrics-to-prometheus-metrics.mdx` |
| Failure runbooks | `/resources/support-center/knowledge-base/troubleshooting/` |
| Thread-pool sizing (Fix-stage lever) | `/resources/support-center/knowledge-base/setup-installation/how-to-increase-thread-pool-size.mdx` |
| Per-year OSS changelogs | `/resources/changelogs/oss/<year>.mdx` |

`references/routing.tsv` carries a `docs_path` per symptom; `./route.sh <code>`
prints it alongside the reference and specialist, or `docs: none` when the docs
provably have no answer.

**Deliberately not used: `/concepts/best-practices/**`.** That subtree is the
upstream the 31 `clickhouse-best-practices` rules were curated from. The rules are
the better artifact — pre-digested, already installed, zero retrieval cost. Going
to the docs for design guidance is paying 3k tokens for a worse version of a rule
you already have.

## Context7 — the client-driver lane

Context7 is **not** a second source of ClickHouse server documentation. Its five
ClickHouse-server entries (`/websites/clickhouse`, `/clickhouse/clickhouse`,
`/clickhouse/clickhouse-docs`, …) are the same upstream pages the docs MCP serves
directly, with **no version dimension at all**, and they lose detail in the
summarizing: asked about `parts_to_throw_insert`, Context7 returned the default
but dropped the version note the docs MCP surfaced for the same setting. For
anything server-side, use the docs MCP.

Reach for Context7 in exactly two situations:

**1. The evidence has crossed the wire — the server is fine, the writer isn't.**
`query_log` attributes the damage to one client (five-row micro-batches from a
single `initial_user`, a retry storm, a connection churn pattern), so the question
becomes how *that driver at that version* batches, retries, or times out:

| Driver | Library ID |
|---|---|
| Python `clickhouse-connect` | `/clickhouse/clickhouse-connect` |
| Node `@clickhouse/client` | `/clickhouse/clickhouse-js` |
| Go `clickhouse-go` | `/clickhouse/clickhouse-go` |
| Java / JDBC | `/clickhouse/clickhouse-java` |

For Node, check first whether the `clickhouse-js-node-*` skills are installed —
they're better than a Context7 lookup and cost nothing.

**2. Kubernetes-operator symptoms** — `/altinity/clickhouse-operator`, the one
Context7 entry covering ground the docs MCP doesn't. Relevant when pods
crash-loop or get OOMKilled and the question is about CRDs, the operator's
reconciliation, or how a pod spec became what it is.

`resolve-library-id` is required before `query-docs`, and Context7 caps at 3 calls
per question — it is a deliberate move, not a reflex.

## Egress and budget

Both rules live in `SKILL.md` ("Documentation lookup") and are not restated here.
The two mechanical consequences for retrieval:

- **Sanitizing costs nothing and retrieves better.** The generic form — *"what is
  the default of `parts_to_throw_insert`"*, not *"why is `prod_events_shard3`
  throwing TOO_MANY_PARTS"* — is both the safe query and the one that actually
  matches a docs page. The docs have never heard of your table.
- **The budget is what makes rule 2 above matter.** At ~3 lookups per
  investigation, the difference between `ls` + targeted `head` (~1k) and two blind
  searches (~6k) is most of your allowance.
