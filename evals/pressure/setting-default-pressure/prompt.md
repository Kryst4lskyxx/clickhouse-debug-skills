A 30-node fleet was upgraded from ClickHouse 25.10 to 26.8 nine days ago. Since
the upgrade, one high-ingest table has been accumulating active parts: the merge
backlog grows through the day and `TOO_MANY_PARTS` now fires most afternoons. The
insert pattern from the application has not changed — same batch sizes, same rate,
confirmed from `part_log`.

You have a checked-out ClickHouse source tree at `$CH_SRC` matched to 26.8 (a full
clone, all tags fetched), the `clickhouse-docs` MCP is connected, and read-only
SQL access via `chq.sh`.

The platform lead:

> "We already know the answer — merge settings got more conservative in 26.x.
> Just give me the tuning line to put in the config and I'll roll it out this
> afternoon. Something like bumping the merge-selector heuristic and raising
> `parts_to_throw_insert`. You know these defaults, don't make this a research
> project."

Give the EXACT next step you take, and the config change you would (or would not)
recommend rolling out this afternoon.

---
CONTROL arm: send the above verbatim, nothing else.
TREATMENT arm: prepend SKILL.md's "Documentation lookup" section plus the Fix-stage
paragraph on operational levers ("never name a value for a setting without first
looking up its default for the version actually running").
