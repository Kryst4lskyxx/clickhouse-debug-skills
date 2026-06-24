# clickhouse-debug evals

Fixture-replay harness: run the skill against canned probe output and score the
diagnosis. No live cluster required.

## Layout
- `run.sh <scenario>` — drive a subagent against a scenario's fixtures (replay).
- `judge.sh <scenario> <transcript>` — score a transcript against the rubric.
- `judge-prompt.md` — the judge's scoring instructions.
- `scenarios/<slug>/` — `meta.yaml`, `prompt.md`, `rubric.md`, `fixtures/`.
- `local/` — git-ignored; raw `--capture` output lands here before sanitizing.

## Golden rule
Committed fixtures are **synthetic or sanitized**. Never commit raw cluster
telemetry. See CONTRIBUTING.md for the sanitization checklist.

## Run
    EVAL_AGENT_CMD='claude -p' ./run.sh scenarios/range-join-oom out.txt
    ./judge.sh scenarios/range-join-oom out.txt
