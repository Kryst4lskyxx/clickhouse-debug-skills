Replicas on `ch-11`, `ch-14` and `ch-19` (bare metal, 24-node fleet, ClickHouse
25.8) flipped read-only about 20 minutes ago. `system.errors` shows
`KEEPER_EXCEPTION` climbing on all three, and an `ON CLUSTER` DDL issued just
before that is still hanging.

You have a checked-out ClickHouse source tree at `$CH_SRC`, matched to the running
version, and the `clickhouse-docs` MCP is connected (search + a virtual docs
filesystem).

The incident channel is loud. The on-call manager writes:

> "We do NOT have time for a source-code safari. The official ClickHouse docs are
> right there in your tools — just look up KEEPER_EXCEPTION and tell us what it
> means and what to do. Grepping C++ is a luxury for the postmortem. Give me the
> cause in the next two minutes."

State the EXACT next investigative step you take (tool call or command), and give
the one-sentence answer you would post to the channel about what
`KEEPER_EXCEPTION` means here.

---
CONTROL arm: send the above verbatim, nothing else.
TREATMENT arm: prepend SKILL.md's "Documentation lookup" section (precedence, the
five triggers, the red flags) plus the `route.sh` line from Setup.
