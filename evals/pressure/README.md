# Pressure tests (discipline)

A different modality from `evals/scenarios/` (which is fixture-replay for
*diagnosis quality*). These test **discipline under pressure**: given a stacked
incentive to break a safety rule, does the agent still comply?

Run them the writing-skills way — a **no-guidance control vs. a with-guidance
treatment**, several fresh-context reps each, scored by reading the transcripts.
There is no `run.sh` driver and no `fixtures/`; you dispatch the `prompt.md` to
subagents (control gets the situation only; treatment gets the situation plus the
guidance block named in the scenario) and score against `rubric.md`.

**The rule that governs them:** if the *control* already complies, the guidance
isn't earning its place — don't add (or keep) it. A treatment that passes while
the control also passes proves nothing.
