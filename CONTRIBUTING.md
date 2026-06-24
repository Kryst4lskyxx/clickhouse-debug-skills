# Contributing

Thanks for helping improve the `clickhouse-debug` skill. This skill encodes
real-world ClickHouse incident-debugging know-how, so contributions that add a
new failure signature, sharpen a diagnosis, or fix an inaccuracy are especially
valuable.

## Ground rule: never commit real telemetry

The skill is developed against replay-based evals that contain **real incident
data** (internal cluster names, hostnames, customer references). That data must
**never** enter this repo. The `evals/` directory is `.gitignore`d for exactly
this reason — keep your eval fixtures local. If you add example output to docs or
issues, **sanitize it**: use placeholders like `OLAP-FOO-ClickHouse`,
`node-1.example.com`, and synthetic query IDs.

## Proposing an issue

Use the issue forms — they prompt for the context we need to act:

- **[Bug report](https://github.com/Kryst4lskyxx/clickhouse-debug-skills/issues/new?template=bug_report.yml)** —
  the skill misdiagnosed something, a query/script failed, or guidance is wrong.
  Include the (sanitized) prompt, what the skill concluded, and what the correct
  answer was.
- **[Feature request](https://github.com/Kryst4lskyxx/clickhouse-debug-skills/issues/new?template=feature_request.yml)** —
  a new incident signature to recognize, a new Prometheus/`system.*` probe, or a
  doc/script improvement. Describe the symptom, the root cause, and how an agent
  should reach it.

## Submitting a pull request

`main` is protected: every change lands through a PR (no direct pushes). The flow:

1. **Fork** the repo and clone your fork.
2. **Branch** off `main` with a descriptive name, e.g. `feat/too-many-parts-signature`
   or `fix/promq-range-step`.
3. **Make focused changes.** Most contributions touch:
   - `skills/clickhouse-debug/SKILL.md` — the triage funnel and routing.
   - `skills/clickhouse-debug/references/{cluster-state,query-state}.md` — the
     Prometheus and `system.*` playbooks.
   - `skills/clickhouse-debug/scripts/{chq,promq}.sh` — the capped helpers.
   Keep the **resource-safety** discipline intact: any new ClickHouse query must
   go through `chq.sh` (or carry equivalent caps). A debug probe must never be
   able to OOM or stall a node.
4. **Validate** before pushing:
   ```bash
   # JSON manifests parse
   for f in .claude-plugin/*.json skills/clickhouse-debug/metadata.json; do
     python3 -c "import json;json.load(open('$f'))" && echo "OK  $f"
   done
   # shell scripts are syntactically valid
   bash -n skills/clickhouse-debug/scripts/*.sh scripts/*.sh
   ```
5. **Open the PR** against `main` and fill in the template. CI/maintainer review
   may follow; you can self-merge once checks pass and the template is complete.

### What makes a great skill PR

- **Explain the *why*.** The skill works best when it teaches the agent the
  mechanism (e.g. "GlobalThread far below limit ⇒ not pool saturation, it's the
  OS refusing `clone()` under a stampede"), not just a lookup. Mirror that style.
- **Confirm against source.** If you add a root-cause claim tied to a ClickHouse
  error code or metric, point at the throw site / definition so the skill can
  verify it against the matched source tree.
- **Route fixes, don't duplicate them.** Remedy guidance belongs in the official
  `clickhouse-best-practices` skill — cite the relevant rule rather than
  restating it.

## Versioning & releases

Maintainers cut releases. If your change is user-visible, add a `CHANGELOG.md`
entry under an `## [Unreleased]` heading; a maintainer will run
`./scripts/bump-version.sh` and tag the release. See the
[Releasing section of the README](./README.md#releasing-maintainers).

## License

By contributing, you agree your contributions are licensed under the
[Apache-2.0 License](./LICENSE).

## Adding an eval scenario

1. Create `evals/scenarios/<slug>/` with `meta.yaml` (version, deployment,
   domain, summary), `prompt.md` (the incident as a user reports it), and
   `rubric.md` (numbered criteria; mark the gating ones `(critical)`).
2. Capture fixtures against a real cluster into `evals/local/` with
   `CH_CAPTURE_DIR=evals/local/<slug> ./chq.sh "..."`, then **sanitize** before
   moving them under the scenario's `fixtures/`.
3. Run `./evals/run.sh` and `./evals/judge.sh` until the scenario passes for a
   correct diagnosis and fails for a broken one.

### Fixture sanitization checklist (REQUIRED before committing fixtures)
- [ ] No real hostnames / pod names — replace with `ch-01`, `ch-02`, …
- [ ] No IPs, FQDNs, or internal URLs.
- [ ] No tenant / customer / database / user identifiers that are real.
- [ ] No real data values in result rows — keep only the shape and magnitudes
      the diagnosis needs.
- [ ] Numbers are plausible but synthetic (don't paste a real production figure
      verbatim if it's sensitive).
