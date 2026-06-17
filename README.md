# ClickHouse Debug Skills

An [Agent Skill](https://agentskills.io) for **debugging live ClickHouse clusters and queries** — built to be used from inside a checked-out, version-matched ClickHouse source tree.

It turns your source checkout into an incident cockpit: triage the cluster from the **outside** (Prometheus), drill into the **inside** (read-only `system.*` queries), and **confirm the root cause against the matched source** you're standing in. Every probe is resource-capped so a debug query can never OOM-kill or stall a production node.

> This skill diagnoses. It deliberately defers the *remedy* to the official [`clickhouse-best-practices`](https://github.com/ClickHouse/agent-skills) skill — install that too (see [Companion skill](#companion-skill)).

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

## Companion skill

This skill owns **diagnosis**; the remedy/safety canon lives in the official ClickHouse skills. Install them so the Fix stage can cite concrete rules:

```bash
npx skills add clickhouse/agent-skills
```

If `clickhouse-best-practices` is missing, the skill will tell you to install it before recommending fixes.

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

- `scripts/chq.sh` — read-only ClickHouse HTTP query helper with **resource caps baked into every call** (`max_memory_usage`, `max_execution_time`, `max_rows_to_read`, `readonly=1`, …), aligned to the official `agent-query-safety` rule.
- `scripts/promq.sh` — Prometheus query helper (instant + range modes, pretty-printed).

Reference playbooks live in `references/cluster-state.md` (Prometheus) and `references/query-state.md` (`system.*`).

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

## License

[Apache-2.0](./LICENSE).
