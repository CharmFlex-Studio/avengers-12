# Loop Run Log

One JSON object per run, appended by `avengers-12/lib/append-run-log.sh`.
`preflight.sh` counts today's entries here to enforce `budget.maxRunsPerDay`,
so this file is load-bearing: do not reformat it by hand.
