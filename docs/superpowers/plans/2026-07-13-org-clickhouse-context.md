# orgname-clickhouse-context Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a standalone, private companion skill that layers org-specific ClickHouse context (per-application cluster inventory, dashboards, credentials process, fork mapping, known-incident library) onto the public `clickhouse-debug` skill, plus the two additive touches that let the public skill detect and consume it.

**Architecture:** A separate private plugin repo at `../orgname-clickhouse-context/`, mirroring the public repo's `SKILL.md` + `references/` progressive-disclosure shape, fully partitioned by application under `references/apps/<app>/`. Integration is **passive**: the public skill gains one companion-detection bullet and one gather-inputs line — no code coupling. The private skill is knowledge-only; it runs no probes.

**Tech Stack:** Markdown (skill content), Bash (test harness in the repo's existing `*.test.sh` + `assert.sh` style), JSON (plugin manifest). No runtime dependencies.

## Global Constraints

- **Placeholder token:** every literal `orgname` is a stand-in for the real org name; every `<app>` is filled in per application. Instantiate with `grep -rl orgname . | xargs sed -i '' 's/orgname/<your-org>/g'`. Copy this rule verbatim into the private repo's `README.md`.
- **Secret hygiene (hard rule):** `access.md` holds vault *references* and fetch *process* only — **never** a live credential (password, token, private key). Enforced by the secret-scan test (Task 5).
- **Knowledge-only:** the private skill contains no executable probe logic. All live probing still goes through the public skill's capped `chq.sh` / `promq.sh`.
- **Public skill stays general:** the public `clickhouse-debug` skill MUST remain fully functional with the internal skill absent. The internal layer is strictly optional depth.
- **Tasks 1–5 operate in the NEW repo** `../orgname-clickhouse-context/`. **Task 6 operates in THIS repo** (`clickhouse-debug-skills`). Each task states its working directory explicitly.
- **Test style:** bash tests named `*.test.sh`, sourcing `assert.sh` (`assert_eq`/`assert_contains`/`assert_rc`/`finish`), runnable via `tests/run.sh`. Match the existing repo pattern exactly.

---

## File Structure

New repo `../orgname-clickhouse-context/`:

```
.claude-plugin/plugin.json                                   # plugin manifest
README.md                                                    # what it is + placeholder-instantiation rule
CONTRIBUTING.md                                              # how a team adds/updates apps/<app>/
.gitignore                                                   # local scratch + belt-and-suspenders secret guard
skills/orgname-clickhouse-context/
  SKILL.md                                                   # ALWAYS-LOADED: purpose, app index, consumption rule, safety
  references/
    apps/
      _template/                                             # copy-me skeleton (excluded from index check)
        inventory.md
        dashboards.md
        access.md
        incidents/
          README.md
          _template.md
    incidents-shared.md                                      # cross-app infra incidents
tests/
  assert.sh                                                  # copied helper (assert_*/finish)
  run.sh                                                     # runs every *.test.sh
  structure.test.sh                                          # every apps/<app>/ has required files
  index.test.sh                                              # every real app folder <-> SKILL.md index row
  secret-scan.test.sh                                        # no credential patterns in tracked files
```

This repo (`clickhouse-debug-skills`), Task 6 only:

```
skills/clickhouse-debug/SKILL.md                             # +companion bullet, +gather-inputs line
evals/tests/companion-doc.test.sh                            # asserts both additions present
```

---

### Task 1: Scaffold the private repo (manifest, docs, gitignore, test harness)

**Files:**
- Create: `../orgname-clickhouse-context/.claude-plugin/plugin.json`
- Create: `../orgname-clickhouse-context/README.md`
- Create: `../orgname-clickhouse-context/.gitignore`
- Create: `../orgname-clickhouse-context/tests/assert.sh`
- Create: `../orgname-clickhouse-context/tests/run.sh`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: a valid, empty plugin repo; `tests/assert.sh` exposing `assert_eq`, `assert_contains`, `assert_rc`, `finish`; `tests/run.sh` that runs every `tests/*.test.sh` and exits non-zero if any fail. Later tasks add `*.test.sh` files consumed by `run.sh`.

- [ ] **Step 1: Create the repo and init git**

```bash
mkdir -p ../orgname-clickhouse-context/.claude-plugin \
         ../orgname-clickhouse-context/skills/orgname-clickhouse-context/references/apps \
         ../orgname-clickhouse-context/tests
cd ../orgname-clickhouse-context && git init -q && cd -
```

- [ ] **Step 2: Write the plugin manifest**

Create `../orgname-clickhouse-context/.claude-plugin/plugin.json`:

```json
{
  "name": "orgname-clickhouse-context",
  "version": "0.1.0",
  "description": "PRIVATE internal companion to clickhouse-debug: per-application ClickHouse cluster inventory, dashboards, credential process, fork mapping, and known-incident library. Loaded passively by clickhouse-debug during triage.",
  "author": { "name": "orgname" },
  "license": "UNLICENSED",
  "keywords": ["clickhouse", "internal", "runbook", "incident-response"],
  "skills": ["./skills/orgname-clickhouse-context/"]
}
```

- [ ] **Step 3: Write the README (carries the placeholder rule verbatim)**

Create `../orgname-clickhouse-context/README.md`:

```markdown
# orgname-clickhouse-context (PRIVATE)

Internal companion to the public `clickhouse-debug` skill. Adds org-specific
context so an operator doesn't have to recite cluster names, label schemes, and
endpoints during an incident — and so prior RCAs are one lookup away.

**This repo is private. Never publish it and never commit live credentials.**

## Placeholder instantiation

Every literal `orgname` in this repo is a stand-in for your real org name; every
`<app>` is filled in per application. To instantiate:

    grep -rl orgname . | xargs sed -i '' 's/orgname/<your-org>/g'

(Drop the `''` after `-i` on GNU sed / Linux.)

## Adding an application

Copy `skills/orgname-clickhouse-context/references/apps/_template/` to
`.../apps/<app>/`, fill it in, and add each cluster to the application index in
`skills/orgname-clickhouse-context/SKILL.md`. See `CONTRIBUTING.md`.

## Tests

    bash tests/run.sh
```

- [ ] **Step 4: Write the .gitignore**

Create `../orgname-clickhouse-context/.gitignore`:

```gitignore
# local operator scratch — never shared
*.local
.chenv
scratch/

# belt-and-suspenders: never commit obvious secret files
*.pem
*.key
*_secret*
```

- [ ] **Step 5: Copy the test harness helper**

Create `../orgname-clickhouse-context/tests/assert.sh`:

```bash
#!/usr/bin/env bash
# Minimal assertions for shell unit tests. Source this; call assert_* ; finish.
_assert_fails=0
assert_eq() {  # msg expected actual
  if [ "$2" != "$3" ]; then
    echo "  FAIL: $1: expected [$2] got [$3]"; _assert_fails=1
  fi
}
assert_contains() {  # msg haystack needle
  case "$2" in *"$3"*) ;; *) echo "  FAIL: $1: [$2] missing [$3]"; _assert_fails=1;; esac
}
assert_rc() {  # msg expected-rc actual-rc
  if [ "$2" != "$3" ]; then echo "  FAIL: $1: expected rc $2 got $3"; _assert_fails=1; fi
}
finish() {  # name
  if [ "$_assert_fails" -eq 0 ]; then echo "PASS: $1"; else echo "FAILED: $1"; fi
  exit "$_assert_fails"
}
```

- [ ] **Step 6: Write the test runner**

Create `../orgname-clickhouse-context/tests/run.sh`:

```bash
#!/usr/bin/env bash
# Run every *.test.sh in this dir; non-zero exit if any fails.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fails=0
shopt -s nullglob
for t in "$HERE"/*.test.sh; do
  echo "== $(basename "$t") =="
  bash "$t" || fails=1
done
exit "$fails"
```

- [ ] **Step 7: Verify manifest is valid JSON and runner runs clean (no tests yet)**

Run:
```bash
cd ../orgname-clickhouse-context
python3 -c "import json; json.load(open('.claude-plugin/plugin.json')); print('plugin.json OK')"
bash tests/run.sh; echo "runner rc=$?"
cd -
```
Expected: `plugin.json OK`, then no `== ... ==` lines (no tests yet) and `runner rc=0`.

- [ ] **Step 8: Commit**

```bash
cd ../orgname-clickhouse-context
git add -A && git commit -q -m "chore: scaffold orgname-clickhouse-context plugin + test harness"
cd -
```

---

### Task 2: Structure lint + app template skeleton

**Files:**
- Create: `../orgname-clickhouse-context/tests/structure.test.sh`
- Create: `../orgname-clickhouse-context/skills/orgname-clickhouse-context/references/apps/_template/inventory.md`
- Create: `.../apps/_template/dashboards.md`
- Create: `.../apps/_template/access.md`
- Create: `.../apps/_template/incidents/README.md`
- Create: `.../apps/_template/incidents/_template.md`

**Interfaces:**
- Consumes: `tests/assert.sh`, `tests/run.sh` from Task 1.
- Produces: the `apps/_template/` skeleton (the copy-me source for every real app) and `structure.test.sh`, which asserts every `references/apps/*/` directory contains `inventory.md`, `dashboards.md`, `access.md`, and `incidents/README.md`.

- [ ] **Step 1: Write the failing structure test**

Create `../orgname-clickhouse-context/tests/structure.test.sh`:

```bash
#!/usr/bin/env bash
# Every references/apps/<app>/ must carry the required files.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
APPS="$HERE/../skills/orgname-clickhouse-context/references/apps"

req="inventory.md dashboards.md access.md incidents/README.md"
found_any=0
for d in "$APPS"/*/; do
  [ -d "$d" ] || continue
  found_any=1
  app="$(basename "$d")"
  for f in $req; do
    if [ -f "$d$f" ]; then
      assert_eq "$app has $f" "yes" "yes"
    else
      assert_eq "$app has $f" "yes" "no"
    fi
  done
done
assert_eq "at least one app dir exists" "1" "$found_any"
finish structure.test.sh
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd ../orgname-clickhouse-context && bash tests/structure.test.sh; echo rc=$?; cd -`
Expected: FAIL — `at least one app dir exists: expected [1] got [0]`, `FAILED: structure.test.sh`, `rc=1`.

- [ ] **Step 3: Write `apps/_template/inventory.md`**

Create `.../references/apps/_template/inventory.md`:

```markdown
# <app> — cluster inventory

> Copy this folder to `apps/<app>/` and replace every ALL-CAPS placeholder.
> Add each cluster below to the application index in `SKILL.md`.

## Environments

| Env | Cluster name | Prom label scheme | HTTP endpoint | Proxy-fronted? | Nodes | Deploy |
|-----|--------------|-------------------|---------------|----------------|-------|--------|
| prod | CLUSTER_NAME | `cluster="CLUSTER_NAME"` | `https://HOST:8443` | yes (chproxy) | NN | k8s |
| staging | CLUSTER_NAME_STG | `cluster="CLUSTER_NAME_STG"` | `http://HOST:8123` | no | NN | bare-metal |

## Notes for the debugger

- **Proxy-fronted** clusters: wrap `system.*` in
  `clusterAllReplicas(CLUSTER_NAME, system.<table>)` and select `hostName()`.
- **Node count** is the fan-out cap-sizing input for the public skill's
  resource-safety section (size `CH_MAX_ROWS` ≈ per-node rows × node count).
- **Deploy type** (bare-metal vs k8s) selects the failure-mode playbook
  (node-down vs pod OOMKilled/crash-loop).
```

- [ ] **Step 4: Write `apps/_template/dashboards.md`**

Create `.../references/apps/_template/dashboards.md`:

```markdown
# <app> — dashboards & runbooks

Reference pointers only (no secrets).

- **Grafana (overview):** URL
- **Grafana (ClickHouse internals):** URL
- **Runbook:** URL
- **On-call rota:** URL
- **Incident comms:** channel / convention
```

- [ ] **Step 5: Write `apps/_template/access.md`**

Create `.../references/apps/_template/access.md`:

```markdown
# <app> — access & source

**NEVER put a live credential in this file. Vault reference + process only.**

## Read-only credentials

- **Vault path:** `VAULT/PATH/TO/readonly-creds`
- **Fetch:** how to retrieve it (command / UI step). Output goes into `.chenv`
  as `CH_USER` / `CH_PASS` for the public skill's `chq.sh` — never committed.

## Source tree / version

- **Runs a fork?** yes/no
- **Source tree location:** path or repo URL (feeds `preflight.sh` version-match)
- **Version → branch map:** e.g. `24.8.x → release/24.8-orgname`
```

- [ ] **Step 6: Write `apps/_template/incidents/README.md`**

Create `.../references/apps/_template/incidents/README.md`:

```markdown
# <app> — known-incident index

Symptom → incident file. Keep this greppable (mirrors the public skill's
`route.sh` lookup shape). One row per incident.

| Symptom / error | Incident file |
|-----------------|---------------|
| SYMPTOM_OR_ERROR_CODE | ./YYYY-MM-DD-slug.md |
```

- [ ] **Step 7: Write `apps/_template/incidents/_template.md`**

Create `.../references/apps/_template/incidents/_template.md`:

```markdown
# YYYY-MM-DD — <one-line incident title>

**Symptom:** what was observed (alert, error code, node/pod).
**Mechanism:** the actual cause (not the symptom).
**Source confirmation:** `file:line` in the matched CH tree.
**Resolution:** what fixed it / stopped the bleeding.
**Blast radius:** one node or fleet-wide; urgent or latent.
**Recurs when:** the precondition, so the next instance is minutes not hours.
```

- [ ] **Step 8: Run the structure test to verify it passes**

Run: `cd ../orgname-clickhouse-context && bash tests/structure.test.sh; echo rc=$?; cd -`
Expected: `PASS: structure.test.sh`, `rc=0`.

- [ ] **Step 9: Commit**

```bash
cd ../orgname-clickhouse-context
git add -A && git commit -q -m "feat: apps/_template skeleton + structure lint"
cd -
```

---

### Task 3: SKILL.md (always-loaded entry point) + app-index consistency test

**Files:**
- Create: `../orgname-clickhouse-context/tests/index.test.sh`
- Create: `../orgname-clickhouse-context/skills/orgname-clickhouse-context/SKILL.md`

**Interfaces:**
- Consumes: `tests/assert.sh`; the `apps/_template/` layout from Task 2.
- Produces: `SKILL.md` carrying the application index (the only always-loaded inventory data) and the consumption rule; `index.test.sh` enforcing that every **real** app folder (every `apps/*/` except `_template`) appears in the SKILL.md index, and every app named in the index has a folder.

- [ ] **Step 1: Write the failing index-consistency test**

Create `../orgname-clickhouse-context/tests/index.test.sh`:

```bash
#!/usr/bin/env bash
# Bidirectional app-index consistency between SKILL.md and apps/ folders.
# _template is a skeleton, not a real app: excluded from both directions.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
ROOT="$HERE/../skills/orgname-clickhouse-context"
SKILL="$ROOT/SKILL.md"
APPS="$ROOT/references/apps"

assert_eq "SKILL.md exists" "yes" "$([ -f "$SKILL" ] && echo yes || echo no)"

# Folder -> index: every real app dir name appears in the index block.
for d in "$APPS"/*/; do
  [ -d "$d" ] || continue
  app="$(basename "$d")"
  [ "$app" = "_template" ] && continue
  if grep -q "apps/$app/" "$SKILL"; then
    assert_eq "index references app '$app'" "yes" "yes"
  else
    assert_eq "index references app '$app'" "yes" "no"
  fi
done

# Index -> folder: every apps/<x>/ path cited in SKILL.md has a real dir.
grep -oE 'apps/[A-Za-z0-9_.-]+/' "$SKILL" | sort -u | while read -r ref; do
  app="$(basename "$ref")"
  [ "$app" = "_template" ] && continue
  [ -d "$APPS/$app" ] || echo "  FAIL: index cites apps/$app/ but no such dir"
done | (grep -q FAIL && { echo "FAILED: index.test.sh"; exit 1; } || true)

finish index.test.sh
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd ../orgname-clickhouse-context && bash tests/index.test.sh; echo rc=$?; cd -`
Expected: FAIL — `SKILL.md exists: expected [yes] got [no]`, `FAILED: index.test.sh`, `rc=1`.

- [ ] **Step 3: Write SKILL.md**

Create `../orgname-clickhouse-context/skills/orgname-clickhouse-context/SKILL.md`:

```markdown
---
name: orgname-clickhouse-context
description: >-
  Internal, org-specific context for ClickHouse incident debugging: per-application
  cluster inventory (names, Prometheus label schemes, endpoints, proxy/topology),
  dashboards and runbooks, the read-only credential retrieval process, fork/source-tree
  mapping, and a known-incident library. Companion to the public clickhouse-debug skill —
  clickhouse-debug loads this during the Frame stage to resolve a cluster/pod/app to its
  real facts instead of asking the operator to recite them. Knowledge only; runs no probes.
license: UNLICENSED
metadata:
  author: orgname
  version: "0.1.0"
---

# orgname ClickHouse context (internal companion)

This skill is **knowledge, not tooling**. It carries the org-specific facts the
public `clickhouse-debug` skill would otherwise ask an operator to recite mid-incident,
plus the org's prior RCAs. All live probing still goes through `clickhouse-debug`'s
capped `chq.sh` / `promq.sh` — this skill runs nothing.

## How clickhouse-debug should consume this

1. From the symptom, identify the **cluster / pod / application** in play (ask if ambiguous).
2. Resolve it to an application via the **application index** below.
3. Load only that app's folder — `references/apps/<app>/`:
   - `inventory.md` → cluster name, Prometheus label scheme, HTTP endpoint(s),
     proxy-fronted flag, node count, deploy type. Feeds `.chenv` setup and the
     fan-out cap sizing in the public skill's resource-safety section.
   - `dashboards.md` → where to look (Grafana/runbooks/on-call).
   - `access.md` → vault path + fetch process for read-only creds; fork/source mapping
     for the version-match preflight.
   - `incidents/README.md` → scan symptom → prior RCA before drilling from scratch.
4. For cross-application infra symptoms (Keeper, network, shared storage), also check
   `references/incidents-shared.md`.

## Safety

`access.md` holds **vault references and process only — never a live credential.**
Read-only accounts are the write guardrail; this skill never weakens that.

## Application index

One row per cluster. When the operator pastes just a cluster or pod name, match it here
to find the owning app and env, then load `references/apps/<app>/`.

| Cluster name | Env | Application | Folder |
|--------------|-----|-------------|--------|
| _(add real clusters here as apps are onboarded — see CONTRIBUTING.md)_ | | | |

<!--
Example row once app "payments" is onboarded:
| ch-payments-prod | prod | payments | apps/payments/ |
-->
```

- [ ] **Step 4: Run the index test to verify it passes**

Run: `cd ../orgname-clickhouse-context && bash tests/index.test.sh; echo rc=$?; cd -`
Expected: `PASS: index.test.sh`, `rc=0` (vacuous — no real apps yet, `_template` excluded, no `apps/<x>/` cited outside the commented example).

- [ ] **Step 5: Commit**

```bash
cd ../orgname-clickhouse-context
git add -A && git commit -q -m "feat: SKILL.md entry point + app-index consistency test"
cd -
```

---

### Task 4: Shared-incidents file + CONTRIBUTING guide

**Files:**
- Create: `../orgname-clickhouse-context/skills/orgname-clickhouse-context/references/incidents-shared.md`
- Create: `../orgname-clickhouse-context/CONTRIBUTING.md`

**Interfaces:**
- Consumes: the layout and conventions established in Tasks 2–3.
- Produces: `incidents-shared.md` (cross-app infra RCAs) and `CONTRIBUTING.md` (the onboarding procedure the README points to). No new test — covered by Task 2's structure test (files sit outside `apps/`) and Task 5's secret scan.

- [ ] **Step 1: Write the shared-incidents file**

Create `.../references/incidents-shared.md`:

```markdown
# Cross-application infrastructure incidents

Incidents in shared infra that are not owned by a single application: Keeper /
ZooKeeper ensembles, the network fabric, shared storage tiers. Same RCA shape as
`apps/<app>/incidents/_template.md`.

| Symptom / error | Incident file / section |
|-----------------|-------------------------|
| _(add cross-app infra incidents here)_ | |
```

- [ ] **Step 2: Write CONTRIBUTING.md**

Create `../orgname-clickhouse-context/CONTRIBUTING.md`:

```markdown
# Contributing to orgname-clickhouse-context

## Onboard an application

1. Copy the template:
   `cp -r skills/orgname-clickhouse-context/references/apps/_template \
          skills/orgname-clickhouse-context/references/apps/<app>`
2. Fill in `inventory.md`, `dashboards.md`, `access.md` — replace every ALL-CAPS
   placeholder. **No live credentials in `access.md`** (vault reference + process only).
3. Add each of the app's clusters to the **application index** table in
   `skills/orgname-clickhouse-context/SKILL.md` (one row per cluster, `Folder` =
   `apps/<app>/`).
4. Record RCAs as `apps/<app>/incidents/YYYY-MM-DD-slug.md` and index them in
   `apps/<app>/incidents/README.md`. Cross-app infra RCAs go in
   `references/incidents-shared.md`.
5. Run the tests: `bash tests/run.sh` — all must PASS before committing.

## Invariants enforced by tests

- Every `apps/<app>/` has `inventory.md`, `dashboards.md`, `access.md`,
  `incidents/README.md` (`structure.test.sh`).
- Every real app folder appears in the SKILL.md index and vice versa
  (`index.test.sh`).
- No credential patterns in tracked files (`secret-scan.test.sh`).
```

- [ ] **Step 3: Run the full suite to confirm nothing regressed**

Run: `cd ../orgname-clickhouse-context && bash tests/run.sh; echo rc=$?; cd -`
Expected: `PASS: structure.test.sh`, `PASS: index.test.sh`, `rc=0`.

- [ ] **Step 4: Commit**

```bash
cd ../orgname-clickhouse-context
git add -A && git commit -q -m "feat: shared-incidents file + CONTRIBUTING guide"
cd -
```

---

### Task 5: Secret-scan guard test

**Files:**
- Create: `../orgname-clickhouse-context/tests/secret-scan.test.sh`

**Interfaces:**
- Consumes: `tests/assert.sh`; a git repo (uses `git ls-files` to scan only tracked files).
- Produces: `secret-scan.test.sh` — fails if any tracked file contains an obvious credential pattern. Self-verifying: it proves it catches a planted secret in a temp file before asserting the real tree is clean.

- [ ] **Step 1: Write the secret-scan test (with self-check)**

Create `../orgname-clickhouse-context/tests/secret-scan.test.sh`:

```bash
#!/usr/bin/env bash
# Fail if any tracked file contains an obvious credential. Placeholder tokens
# (ALL-CAPS PATH/VAULT stand-ins) are allowed; real-looking assignments are not.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/assert.sh"
cd "$HERE/.."

# Patterns that indicate a real secret leaked into the repo.
PAT='(-----BEGIN [A-Z ]*PRIVATE KEY-----)'
PAT="$PAT|(password[[:space:]]*[:=][[:space:]]*[^[:space:]\"'\`<]{6,})"
PAT="$PAT|(CH_PASS[[:space:]]*=[[:space:]]*[^[:space:]\"'\`<]{4,})"
PAT="$PAT|(xox[baprs]-[0-9A-Za-z-]{10,})"           # slack tokens
PAT="$PAT|(gh[pousr]_[0-9A-Za-z]{20,})"             # github tokens

scan() {  # file -> prints matches (grep -E), rc 0 if any match
  git ls-files -z | xargs -0 grep -InEH "$PAT" 2>/dev/null
}

# Self-check: a planted secret MUST be detected.
tmp="planted_secret_check.md"
printf 'password = hunter2supersecret\n' > "$tmp"
git add -N "$tmp" 2>/dev/null || true
planted="$(scan | grep -c "$tmp" || true)"
git rm -q --cached "$tmp" 2>/dev/null || true
rm -f "$tmp"
assert_eq "self-check detects a planted secret" "1" "$([ "$planted" -ge 1 ] && echo 1 || echo 0)"

# Real tree MUST be clean.
hits="$(scan | grep -v 'planted_secret_check.md' || true)"
if [ -n "$hits" ]; then
  echo "  FAIL: credential-like content in tracked files:"; echo "$hits"
  assert_eq "tree is clean of secrets" "clean" "dirty"
else
  assert_eq "tree is clean of secrets" "clean" "clean"
fi

finish secret-scan.test.sh
```

- [ ] **Step 2: Run it — expect PASS (self-check catches the plant, tree is clean)**

Run: `cd ../orgname-clickhouse-context && bash tests/secret-scan.test.sh; echo rc=$?; cd -`
Expected: `PASS: secret-scan.test.sh`, `rc=0`.

- [ ] **Step 3: Prove it actually fails on a real leak (temporary, reverted)**

Run:
```bash
cd ../orgname-clickhouse-context
printf '\nCH_PASS=realLeakedPassword123\n' >> skills/orgname-clickhouse-context/references/apps/_template/access.md
git add skills/orgname-clickhouse-context/references/apps/_template/access.md
bash tests/secret-scan.test.sh; echo rc=$?
git checkout -- skills/orgname-clickhouse-context/references/apps/_template/access.md
git reset -q
cd -
```
Expected: `FAIL: credential-like content...`, `FAILED: secret-scan.test.sh`, `rc=1`. (Then the file is restored — confirm `git status` is clean.)

- [ ] **Step 4: Run the full suite**

Run: `cd ../orgname-clickhouse-context && bash tests/run.sh; echo rc=$?; cd -`
Expected: three `PASS:` lines, `rc=0`.

- [ ] **Step 5: Commit**

```bash
cd ../orgname-clickhouse-context
git add -A && git commit -q -m "test: secret-scan guard for tracked files"
cd -
```

---

### Task 6: Public-skill integration (this repo) — companion bullet + gather-inputs line

**Files:**
- Modify: `skills/clickhouse-debug/SKILL.md` (this repo)
- Create: `evals/tests/companion-doc.test.sh` (this repo)

**Interfaces:**
- Consumes: nothing from the private repo at runtime (passive — prose only). References the internal skill by convention name.
- Produces: two additive edits to the public SKILL.md and a doc test asserting both are present. The public skill must still read correctly with the internal skill absent.

- [ ] **Step 1: Write the failing doc test**

Create `evals/tests/companion-doc.test.sh` (in THIS repo):

```bash
#!/usr/bin/env bash
# Asserts the public SKILL.md documents the optional internal context companion.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
SKILL="skills/clickhouse-debug/SKILL.md"
fail=0

grep -q "orgname-clickhouse-context" "$SKILL" || {
  echo "FAIL: SKILL.md must name the internal companion (orgname-clickhouse-context)"; fail=1; }
grep -q "internal" "$SKILL" || {
  echo "FAIL: SKILL.md must describe the companion as internal/optional"; fail=1; }
# The gather-inputs integration must say facts come from the companion when present.
grep -qi "application index" "$SKILL" || {
  echo "FAIL: SKILL.md must reference resolving via the application index"; fail=1; }

[ "$fail" -eq 0 ] && echo "PASS: companion-doc.test.sh"
exit "$fail"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash evals/tests/companion-doc.test.sh; echo rc=$?`
Expected: FAIL — three `FAIL:` lines, `rc=1`.

- [ ] **Step 3: Add the companion bullet to the public SKILL.md**

In `skills/clickhouse-debug/SKILL.md`, find the end of companion block 3 (the
`altinity-profiler-clickhouse` paragraph). Insert a new block immediately after it,
before the `**Detecting them (do this explicitly, up front):**` paragraph.

Replace this exact text:

```
load an existing `<cluster>-analyst` skill, or offer to run the profiler once while
the cluster is calm.

**Detecting them (do this explicitly, up front):**
```

with:

```
load an existing `<cluster>-analyst` skill, or offer to run the profiler once while
the cluster is calm.

**4. An internal ClickHouse-context companion (optional, org-private).** Some orgs
ship a private companion (named per org, e.g. `orgname-clickhouse-context`) carrying
per-application cluster inventory (names, Prometheus label schemes, endpoints,
proxy/topology), dashboards/runbooks, the read-only credential retrieval process,
fork/source-tree mapping, and a known-incident library. It is **knowledge only** — it
runs no probes. If present, load it in the Frame stage: resolve the cluster/pod/app to
its real facts via its **application index** instead of asking the operator to recite
them, and scan its incident library before drilling from scratch. If absent, use the
gather-inputs flow below unchanged.

**Detecting them (do this explicitly, up front):**
```

- [ ] **Step 4: Add the gather-inputs line**

In `skills/clickhouse-debug/SKILL.md`, find the sentence that closes the
"Before you touch anything: gather inputs" section.

Replace this exact text:

```
Confirm the gathered setup back to the user in one line before running probes, so
a wrong cluster/endpoint is caught before any query hits production.
```

with:

```
If an internal ClickHouse-context companion (e.g. `orgname-clickhouse-context`) is
present, resolve items 2–3 — and any fork/source specifics for item 5 — from its
**application index** and per-app `inventory.md` / `access.md` instead of asking the
user to recite them; fall back to asking only for what it doesn't cover.

Confirm the gathered setup back to the user in one line before running probes, so
a wrong cluster/endpoint is caught before any query hits production.
```

- [ ] **Step 5: Run the doc test to verify it passes**

Run: `bash evals/tests/companion-doc.test.sh; echo rc=$?`
Expected: `PASS: companion-doc.test.sh`, `rc=0`.

- [ ] **Step 6: Confirm no existing tests regressed**

Run:
```bash
bash skills/clickhouse-debug/scripts/tests/run.sh; echo "scripts rc=$?"
bash evals/tests/gitignore.test.sh; echo "gitignore rc=$?"
```
Expected: existing suites still pass (`rc=0` each). (Network-dependent replay tests may skip; no new failures introduced by a docs edit.)

- [ ] **Step 7: Commit**

```bash
git add skills/clickhouse-debug/SKILL.md evals/tests/companion-doc.test.sh
git commit -m "feat: document optional internal clickhouse-context companion (passive integration)"
```

---

## Self-Review

**1. Spec coverage:**
- Separate private skill → Task 1 (repo/manifest). ✓
- Cluster inventory → Task 2 (`inventory.md`). ✓
- Dashboards & runbook links → Task 2 (`dashboards.md`). ✓
- Known-incident library → Task 2 (`incidents/`), Task 4 (`incidents-shared.md`). ✓
- Creds & fork specifics → Task 2 (`access.md`). ✓
- Per-application partition → `apps/<app>/` layout, Tasks 2–4. ✓
- Load-bearing application index → Task 3 (SKILL.md). ✓
- Passive integration (companion bullet + gather-inputs line) → Task 6. ✓
- Public skill stays general → Task 6 phrasing + "absent" fallbacks; asserted implicitly. ✓
- Secret hygiene → `.gitignore` (Task 1), `access.md` warning (Task 2), secret-scan (Task 5). ✓
- Testing (structure lint, index consistency, secret scan) → Tasks 2, 3, 5. ✓
- CONTRIBUTING → Task 4. ✓
- Placeholder rule → Global Constraints + README (Task 1) + SKILL description. ✓

**2. Placeholder scan:** All `orgname`/`<app>`/ALL-CAPS tokens are intentional, documented template variables (Global Constraints). No TBD/TODO, no "add error handling"-style vagueness; every code/markdown step shows full content.

**3. Type/name consistency:** `assert_eq`/`assert_contains`/`assert_rc`/`finish` used as defined in Task 1's `assert.sh`. `tests/run.sh` globs `*.test.sh` (Task 1) and picks up `structure`/`index`/`secret-scan` tests. Skill path `skills/orgname-clickhouse-context/` consistent across manifest (T1), structure test (T2), index test (T3), CONTRIBUTING (T4). Index test excludes `_template` in both directions, matching the SKILL.md commented example.
