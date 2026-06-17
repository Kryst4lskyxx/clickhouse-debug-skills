<!-- Thanks for contributing! Keep changes focused and read CONTRIBUTING.md. -->

## What & why

<!-- What does this change? What incident/symptom or gap does it address? -->

## Type of change

- [ ] New incident signature / diagnosis
- [ ] New or improved probe (Prometheus / `system.*`)
- [ ] Fix (wrong guidance, broken script, typo)
- [ ] Docs / metadata
- [ ] Other:

## Checklist

- [ ] No real cluster telemetry committed; examples are sanitized (placeholders, synthetic IDs)
- [ ] Any new ClickHouse query goes through `chq.sh` or carries equivalent resource caps
- [ ] JSON manifests parse and shell scripts pass `bash -n`
- [ ] New root-cause claims are confirmed against ClickHouse source (error code / metric)
- [ ] Fixes route to `clickhouse-best-practices` rules rather than duplicating remedy guidance
- [ ] `CHANGELOG.md` updated under `## [Unreleased]` if user-visible
