# ClickHouse Debug Skills

[![Release](https://img.shields.io/github/v/release/Kryst4lskyxx/clickhouse-debug-skills?sort=semver)](https://github.com/Kryst4lskyxx/clickhouse-debug-skills/releases)
[![License](https://img.shields.io/github/license/Kryst4lskyxx/clickhouse-debug-skills)](./LICENSE)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](./CONTRIBUTING.md)
[![Issues](https://img.shields.io/github/issues/Kryst4lskyxx/clickhouse-debug-skills)](https://github.com/Kryst4lskyxx/clickhouse-debug-skills/issues)

An [Agent Skill](https://agentskills.io) for **debugging live ClickHouse clusters and queries** — built to be used from inside a checked-out, version-matched ClickHouse source tree.

It turns your source checkout into an incident cockpit: triage the cluster from the **outside** (Prometheus), drill into the **inside** (read-only `system.*` queries), and **confirm the root cause against the matched source** you're standing in. Every probe is resource-capped so a debug query can never OOM-kill or stall a production node.

> This skill diagnoses. It defers the *remedy* to ClickHouse's official [`clickhouse-best-practices`](https://github.com/ClickHouse/agent-skills), and borrows deeper `system.*` playbooks plus a per-cluster schema map from the [Altinity skills](https://github.com/Altinity/altinity-skills) — install all three (see [Companion skills](#companion-skills)).

## Installation

### npx (Claude Code, Cursor, Copilot, …)

```bash
npx skills add Kryst4lskyxx/clickhouse-debug-skills
```

The CLI auto-detects your installed agents and prompts you where to install.

### Claude Code plugin marketplace

```text
/plugin marketplace add Kryst4lskyxx/clickhouse-debug-skills
/plugin install clickhouse-debug@clickhouse-debug-skills
```

### Manual

Copy `skills/clickhouse-debug/` into your agent's skills directory (e.g. `~/.claude/skills/` for Claude Code, `~/.agents/skills/` for the agentskills.io layout).

## Companion skills

This skill owns **diagnosis**. Three companion suites cover everything around it — install all three:

```bash
npx skills add clickhouse/agent-skills                                 # Fix canon: clickhouse-best-practices (+ architecture-advisor)
npx skills add Altinity/altinity-skills/altinity-expert-clickhouse/    # diagnosis depth: per-domain system.* playbooks
npx skills add Altinity/altinity-skills/altinity-profiler-clickhouse/  # cluster map: per-cluster schema knowledge base
```

- **`clickhouse-best-practices`** — the remedy/safety canon. The Fix stage cites its rules instead of improvising, and `chq.sh`'s caps follow its `agent-query-safety` rule.
- **`altinity-expert-clickhouse-*`** — deep `system.*` playbooks (caches, dictionaries, kafka, mutations, grants, index-analysis, storage, …). The Inside stage routes into the matching specialist; any borrowed SQL is re-run through `chq.sh` so the caps still apply (the specialists assume an uncapped session).
- **`altinity-profiler-clickhouse`** — generates a `<cluster>-analyst` schema map used in the Frame stage when a diagnosis needs the cluster's tables/engines/keys.

If a suite is missing, the skill says so and continues with reduced depth — uncited fixes, and `system.*` drilling limited to its own references.

## What it does

| Stage | Source | What you learn |
|-------|--------|----------------|
| **Triage (outside)** | Prometheus | node up/down/flapping, OOM-kills, CPU/iowait/load, disk health (incl. SATA-vs-NVMe tier mismatch), network, bare-metal vs k8s (exit 137 OOMKilled / 139 SIGSEGV) |
| **Forensics (inside)** | `system.*` over read-only HTTP | `errors`, `query_log` (with query attribution: who/where/native-vs-http/fan-out), `processes`, `parts`/`part_log`/`merges`, `replicas`, thread-pool & FD exhaustion, `settings` |
| **Confirmation** | matched source tree | error code → throw site, metric → semantics — no guessing across versions |
| **Fix routing** | `clickhouse-best-practices` | delegates the remedy to the official rules and cites them in the writeup |

It recognizes real-world incident signatures, e.g. range-JOIN OOM, `CANNOT_SCHEDULE_TASK` admission stampede, failing-merge retry storm from a dead disk (`FILE_DOESNT_EXIST`), and FD-exhaustion → throwing-destructor → SIGSEGV.

## Usage

1. **Check out ClickHouse at the cluster's version** and `cd` into it.
2. **Point the skill at your telemetry** by exporting connection details:

   ```bash
   export PROM='https://prometheus.example.com'       # Prometheus base URL
   export CH_URL='http://chnode.example.com:8123'      # or https://…:8443
   export CH_USER='readonly_user'
   export CH_PASS='…'                                  # optional
   ```

3. **Ask your agent**, e.g.:
   > "Our cluster is throwing Code 439 CANNOT_SCHEDULE_TASK in per-minute bursts. Prometheus and a read-only HTTP user are set up, it's on k8s. What's the root cause and how do I fix it?"

The skill gathers the inputs it needs (the problem, the target in Prometheus, connection details, bare-metal vs k8s — it asks if you didn't say), runs a capped triage funnel, and produces a root-cause writeup.

### Bundled helpers

- `scripts/chq.sh` — read-only ClickHouse HTTP query helper with **resource caps baked into every call** (`max_memory_usage`, `max_execution_time`, `max_rows_to_read`, …), aligned to the official `agent-query-safety` rule. Retries once on a transient curl failure and prints a stderr hint naming the exact cap to raise when one trips.
- `scripts/promq.sh` — Prometheus query helper (instant + range modes, pretty-printed). Flags `0 series` (likely a wrong/absent metric name) instead of a silent empty table, and retries once on a transient fetch failure.

Reference playbooks, one per stage: `references/cluster-state.md` (outside / Prometheus), `references/query-state.md` (inside / `system.*`), and `references/source-map.md` (confirm / navigating the matched source tree — the differentiator).

### Evals (maintainers)

A fixture-replay harness lets you measure the skill without a live cluster.
`chq.sh`/`promq.sh` gain two env-gated modes: `CH_CAPTURE_DIR` records a probe's
real output as a fixture; `CH_REPLAY_DIR` returns that fixture instead of hitting
the network. Scenarios live in `evals/scenarios/<slug>/` (`prompt.md`,
`fixtures/`, `rubric.md`, `meta.yaml`). Run one and score it:

    EVAL_AGENT_CMD='claude -p' ./evals/run.sh evals/scenarios/range-join-oom out.txt
    ./evals/judge.sh evals/scenarios/range-join-oom out.txt

Committed fixtures are synthetic/sanitized; raw captures stay in the ignored
`evals/local/`. See CONTRIBUTING.md for the sanitization checklist.

## Safety

Debugging a production cluster must not *become* the incident. Every query this skill issues is read-only and resource-capped, so a probe that would exceed its limits aborts with `MEMORY_LIMIT_EXCEEDED` / `TIMEOUT_EXCEEDED` instead of taking down the node.

## Repository layout

```
.
├── .claude-plugin/          # Claude Code plugin marketplace manifests
│   ├── marketplace.json
│   └── plugin.json
├── skills/clickhouse-debug/  # the skill (SKILL.md + metadata.json + references/ + scripts/)
├── LICENSE                   # Apache-2.0
└── README.md
```

## Contributing

Issues and PRs are welcome — see **[CONTRIBUTING.md](./CONTRIBUTING.md)** for the full guide.

- 🐞 **Found a bug or wrong diagnosis?** [Open a bug report.](https://github.com/Kryst4lskyxx/clickhouse-debug-skills/issues/new?template=bug_report.yml)
- 💡 **Want a new signature, reference, or capability?** [Open a feature request.](https://github.com/Kryst4lskyxx/clickhouse-debug-skills/issues/new?template=feature_request.yml)
- 🔧 **Sending a PR?** Fork → branch → PR against `main` (it's protected; all changes land via PR). Never commit real cluster telemetry — `evals/` is gitignored for a reason.

## Releasing (maintainers)

Versions live in 5 places (SKILL.md frontmatter, `metadata.json`, `plugin.json`,
and two fields in `marketplace.json`). Bump them all at once:

```bash
./scripts/bump-version.sh 0.2.0
# edit CHANGELOG.md, then:
git commit -am "release: v0.2.0"
git tag v0.2.0 && git push && git push --tags
gh release create v0.2.0 --generate-notes
```

`npx skills add` installs from the `main` branch, so keep `main` releasable — do
work on a branch and merge. Plugin-marketplace users update with
`/plugin marketplace update clickhouse-debug-skills` then re-install.

## License

[Apache-2.0](./LICENSE).
