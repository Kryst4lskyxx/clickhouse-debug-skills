# Design: `<org>-clickhouse-context` — internal companion for clickhouse-debug

**Date:** 2026-07-13
**Status:** Approved (design); pending implementation plan
**Author:** Ye Yuan

## Problem

`clickhouse-debug` is a **public**, Apache-2.0 plugin distributed via `npx skills add`
and a marketplace. Internal operators want to layer organization-specific context on
top of it — real cluster names, Prometheus label schemes, dashboards, known-incident
history, credential-retrieval process, and fork/source-tree specifics — **without any
of that leaking into the public repo** and **without forking** the public skill (which
would incur merge drift on every public release).

## Decisions (locked during brainstorming)

| Dimension | Decision |
|---|---|
| Distribution | **Separate private skill** (`<org>-clickhouse-context`), own repo/plugin/version, installed alongside the public skill. Public repo stays 100% clean. |
| Content categories | **All four**: cluster inventory, dashboards & runbook links, known-incident library, creds & fork specifics. |
| Integration | **Passive detect-and-load.** The public skill gains detection + a consumption line only. No code coupling, no machine-readable interface between the two skills. |
| Scale | **Many clusters across multiple envs**, organized **per application** (each app owns its own clusters/envs). |
| Partition | **Everything is per-application** — inventory, dashboards, incidents, creds/vault, and fork/source mapping all follow the app boundary. Only cross-app *infra* incidents get a shared bucket. |

### Rejected alternatives

- **Gitignored files inside the public repo** — relies on `.gitignore` discipline (secrets one `git add .` away) and can't be shared as an installable unit.
- **Consuming repo's CLAUDE.md/.claude** — travels with one repo only; not reusable across teams; unstructured.
- **Fork + overlay** — merge drift every public release.
- **Single flat SKILL.md** — loads the whole inventory + every incident on every trigger; defeats the context budget at multi-env scale.
- **Machine-readable inventory (TSV/YAML)** — premature: with *passive* integration nothing consumes it. A markdown table serves the agent better today (YAGNI). Can be revisited if integration later goes active.
- **Active integration (feed `.chenv`/`chq.sh`, hook `route.sh`)** — deferred; adds a real interface and maintenance surface not needed for the first version.

## Architecture

A standalone private skill mirroring the public skill's `SKILL.md` + `references/`
progressive-disclosure shape, fully partitioned by application so debugging one app
never loads another app's context.

```
<org>-clickhouse-context/
  .claude-plugin/plugin.json        # own plugin manifest (private marketplace)
  SKILL.md                          # ALWAYS-LOADED, kept tiny:
                                    #   - what this layer is + the consumption rule
                                    #   - the application index (app -> clusters, cluster -> app)
                                    #   - the one hard safety rule (vault refs only, never a secret)
  references/
    apps/
      <app>/
        inventory.md                # envs x clusters: PromQL label scheme, HTTP endpoints,
                                    #   proxy-fronted?, node counts, deployment type (bare/k8s)
        dashboards.md               # Grafana/runbook/on-call/comms links for this app
        access.md                   # vault path + fetch process; fork source-tree path + version->branch map
        incidents/
          README.md                 # symptom -> incident index (same lookup shape as route.sh)
          <YYYY-MM-DD-slug>.md      # one known-incident RCA per file
    incidents-shared.md             # cross-app infra incidents (Keeper, network, shared storage)
  CONTRIBUTING.md                   # how a team adds/updates its app folder
  .gitignore                        # guards against committing secrets/local scratch
```

### Load-bearing component: the application index

`SKILL.md` carries a compact **application index** — one row per cluster mapping
`cluster name -> application -> env`. This is the only always-loaded inventory data,
so it must stay small. Its job: when the user pastes just a cluster or pod name, the
agent resolves which app it belongs to, then loads **only** that app's folder under
`references/apps/<app>/`. Keeping it one row per cluster bounds the always-on context
even as the number of apps grows.

## Component detail

### `references/apps/<app>/inventory.md`
Carries exactly the facts the public skill's "Before you touch anything: gather inputs"
section currently asks the user to recite, so they no longer have to. Per environment:
- cluster name(s)
- Prometheus label scheme (`cluster=` / `instance=` / pod naming)
- HTTP endpoint(s) (`http://host:8123` / `https://host:8443`)
- whether it is proxy-fronted (chproxy -> wrap `system.*` in `clusterAllReplicas(<cluster>, ...)`)
- node count (for fan-out cap sizing, per the public skill's resource-safety section)
- deployment type: bare metal vs Kubernetes (changes which metrics exist / failure modes)

### `references/apps/<app>/dashboards.md`
Reference-type pointers only: Grafana boards, runbooks, on-call rota, incident-comms
convention.

### `references/apps/<app>/access.md`
- The vault **path** and the process to fetch the read-only credentials — **never the
  secret itself**.
- If the app runs a fork/patched build: where its source tree lives and the
  version -> branch map. This feeds the public skill's version-match preflight
  (`preflight.sh` compares source `VERSION_STRING` vs live `SELECT version()`).

### `references/apps/<app>/incidents/`
The operator's `memory/` notes promoted to shareable RCAs. Each `<slug>.md`: symptom,
mechanism, `file:line` confirmation, resolution, blast radius. `README.md` maps
symptom -> file so it is greppable the way `route.sh` is.

### `references/incidents-shared.md`
Cross-app infrastructure incidents (Keeper/ZooKeeper, network, shared storage) that
are not owned by a single application.

### `CONTRIBUTING.md`
Convention for a team to add/update its `apps/<app>/` folder: required files, the
"add your cluster to the SKILL.md index too" rule, and the secret-hygiene rule.

## Integration with the public skill (passive — exactly two additive touches)

No code coupling. Both edits are to `skills/clickhouse-debug/SKILL.md`.

1. **Companion bullet** — a 4th entry under "Companion skills (install these first)"
   describing `<org>-clickhouse-context`, following the existing convention: detect it
   in the available-skills list, state whether present or missing, and say what depth
   is lost if absent (no internal cluster inventory / dashboards / incident history →
   fall back to asking the user).
2. **Gather-inputs line** — under "Before you touch anything: gather inputs", note that
   *if* the internal skill is present, cluster names / label scheme / endpoints /
   creds-path / source-fork are resolved from it (via the app index) instead of asking
   the user to recite them; if absent, the current ask-the-user flow is unchanged.

**Invariant:** the public skill remains fully functional and fully general without the
internal skill. The internal layer is strictly optional depth.

## Safety

- **Secret hygiene is the one hard rule.** `access.md` holds vault *references*, never
  live credentials. The private repo ships a `.gitignore` and a `CONTRIBUTING.md` note.
  This inherits the public skill's read-only-creds posture (a properly read-only account
  is the real write guardrail).
- The internal skill is **knowledge only** — it runs no probes and holds no execution
  logic, so it adds no new resource-safety surface. All live probing still goes through
  the public skill's capped `chq.sh` / `promq.sh`.

## Testing

Light, since this is knowledge not code — matching the repo's existing `*.test.sh` style:

1. **Structure lint** — every `references/apps/<app>/` has the required files
   (`inventory.md`, `dashboards.md`, `access.md`, `incidents/README.md`).
2. **Index consistency** — every cluster named in any `inventory.md` appears in the
   `SKILL.md` application index, and vice versa (no orphans, no dangling index rows).
3. **Secret-scan guard** — no obvious credential patterns (passwords, tokens, private
   keys) committed anywhere in the repo.

## Out of scope (this version)

- Active integration: pre-populating `.chenv`, resolving cluster -> labels/endpoints for
  the scripts, or hooking the incident library into `route.sh`. Deferred; revisit only
  if passive proves insufficient.
- Machine-readable inventory format.
- Auto-generation of inventory from a source of truth (e.g. tying into
  `altinity-profiler-clickhouse` output).

## Open questions for the plan phase

- Repo/plugin naming (`<org>` placeholder) and where the private marketplace lives.
- Whether to seed the first `apps/<app>/` folder from an existing real cluster as a
  worked example, or ship an `apps/_template/` skeleton only.
