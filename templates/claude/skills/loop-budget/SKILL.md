---
name: loop-budget
description: Reference for how the loop's caps are enforced. Nothing invokes this skill and nothing here enforces anything — the caps live in bash and the run log is written by avengers-12/lib/append-run-log.sh.
---

# Loop Budget

**Enforcement is not your job, and neither is the run log.** This skill used to ask the
model to sum its own token spend and decide whether to keep going. That is exactly the kind
of guardrail a model should not own: an agent under pressure to finish is the worst
possible judge of whether it should stop.

**Nothing invokes this skill.** The workflow issues exactly two prompts, `/loop-triage` and
`/loop-implement <N>`. Read this when you want to know where a cap comes from; do not
expect it to have run.

Everything that actually caps a run now happens in the harness, before or around you:

| Limit | Enforced by | Where |
|---|---|---|
| Runs per day | `preflight.sh` counting today's entries in `avengers-12/state/run-log.md` | fails the job before Claude starts, and comments on the issue saying so |
| One run at a time | `concurrency: group: loop` in `loop.yml` | GitHub Actions |
| Turns per run | `--max-turns` in `claude_args` | the action |
| Wall clock | `timeout-minutes` | the job |
| Fix attempts | `.loop/attempts.json`, written by `evidence.sh` | read by the orchestrator |
| Kill switch | repo variable `LOOP_PAUSE_ALL` | job-level `if:` **and** `preflight.sh` |
| Timer switch | repo variable `LOOP_PAUSE_SCHEDULE` | `schedule-gate.sh`, scheduled runs only |

If you hit one of these, you will simply stop — there is no negotiation and nothing for you
to decide.

## Who writes the run log

Bash does, on every path, and you should not.

`avengers-12/lib/append-run-log.sh` does the writing. `escalate.sh` calls it on every
non-success path and the workflow's `Record run` step calls it on success, so both halves
are covered by steps that run whether or not an agent is alive to remember. The script also
guards on `GITHUB_RUN_ID` so one run can never produce two entries — a duplicate would skew
`preflight.sh`'s daily-cap count.

Entry shape:

```json
{
  "run_id": "2026-08-16T09:15:00Z",
  "pattern": "implement",
  "outcome": "pr-opened",
  "run_url": "https://github.com/.../actions/runs/123",
  "issue": 42,
  "attempts": 1,
  "files_changed": 4
}
```

`outcome` is one of: `no-op`, `report-only`, `pr-opened`, `escalated`, `gate-failed`, `died`.

## Why the log is worth keeping

Phase 5 of the plan reads it. The useful signal is not total spend — it is the ratio of
`pr-opened` to `escalated`, broken down by what the issue looked like going in. That tells
you whether to fix the issue template or the prompts, and those are different fixes.

Prune entries older than 30 days.
