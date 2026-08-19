# Loop Budget

> **No number in this file is authoritative.** Every cap lives in
> `avengers-12/config.yml` under `budget:`, and this file names the key rather than the
> value. A limit written in two places drifts, and when it drifts the copy you read is the
> wrong one. Run `avengers-12/lib/doctor.sh` to see the values actually in force.

Everything here is enforced by a script, not by asking the model to police itself.

## Limits

| Limit | Value | Enforced by |
|---|---|---|
| Implement runs per day | `budget.maxRunsPerDay` in `avengers-12/config.yml` | `avengers-12/lib/preflight.sh`, before Claude starts |
| Concurrent Loop runs | 1 | `concurrency: group: loop` in `loop.yml` |
| Turns per implement run | `models.implement.maxTurns` in `avengers-12/config.yml` | `--max-turns` in `claude_args`, emitted by `avengers-12/lib/emit-config.sh` |
| Wall clock per run | 45 min | `timeout-minutes` in `loop.yml` — the one cap that is not in config, because Actions will not read it from a file |
| Fix attempts per **run** | `budget.maxAttemptsPerRun` in `avengers-12/config.yml` | `.loop/attempts.json` via `avengers-12/lib/evidence.sh` |
| Triage runs | unmetered (~2 min, read-only) | — |

Two of those are easy to misread:

- **The concurrency group is `loop`, not `loop-implement`,** and it covers both jobs. A
  comment-triggered resume therefore queues behind a dispatch that is already running
  rather than racing it.
- **Attempts are counted per run, not per issue.** `preflight.sh` writes a fresh `attempts.json`
  each run, so a second run on the same issue starts at 1 again. That is intended — a new
  run means a new brief and often a human answer — but the daily cap, not the attempt
  counter, is what bounds total spend on one stubborn issue.

## What a run actually costs

**Claude usage** bills against the subscription behind `CLAUDE_CODE_OAUTH_TOKEN`, not API
credits.

**Actions minutes** are the cash cost, and this repo is private, so they come out of the
monthly allowance (2,000 on Free, 3,000 on Pro/Team):

| Job | Wall clock | Allowance burned |
|---|---|---|
| Triage | ~2 min | 2 min |
| Implement, one attempt | ~12 min | 12 min |
| Implement, three attempts | ~30 min | 30 min |

Linux bills 1×. macOS bills 10×, which is why the gate does not compile iOS — adding it
would cut roughly 375 runs a month down to about 28.

## Kill switch

Set repo variable `LOOP_PAUSE_ALL` to `true`. `loop.yml` skips at the job level, and
`preflight.sh` checks it again in case it was flipped while a run was queued.

Resume by setting it back to `false`.

## On budget exceed

`preflight.sh` fails the job with an explanation before any tokens are spent, **and
comments on the issue** saying the cap was hit and when it resets. That comment matters:
the refusal happens before the issue is claimed, so `escalate.sh` deliberately leaves the
issue untouched, and without it the owner would see a red run against their issue with no
reason anywhere near it.

The issue keeps its labels and stays in the queue. Raise `budget.maxRunsPerDay` in
`avengers-12/config.yml` or wait — there is nothing to clean up, because nothing started.

## Reading the spend

`avengers-12/state/run-log.md` holds one JSON entry per run. The number worth watching is not total
spend, it is the ratio of `pr-opened` to `escalated` and which issue shapes land in each
bucket — that tells you whether to fix the issue template or the prompts.

## Alerts this period

<!-- append notable events here -->
