# Changelog

## 0.2.0 — unreleased

Setup no longer starts at a blank config file, and a board that cannot be driven
says so instead of failing silently.

- `/setup-workflow` skill. Run it after `init`: it reads what kind of project this
  is, writes `config.yml` from that, creates the labels, and hands back the setup
  steps that happen in a browser and cannot be automated.
- `lib/detect-project.sh` — reports the project's build files, test directories,
  nested builds and secret-shaped files as JSON. Facts only; it makes no
  decisions, because a detector that guessed your build command would be wrong
  silently and "verify passed" would stop meaning anything.
- `lib/setup-status.sh` — reports which setup steps already left a trace: labels,
  variable and secret *names*, and whether the workflows reached the default
  branch. Never reads a secret value.
- `lib/check-board.sh`, run by `doctor` — verifies the board resolves and that
  every column named in `board.columns` exists on it. Board operations are
  non-fatal by design, so a card that cannot move used to produce one warning in
  a job log and nothing else. A default GitHub Project has only Todo, In Progress
  and Done, so In Review and Blocked silently did nothing on a fresh board.

Fixed:

- `loop.yml` moved cards to a hardcoded `"In Review"` instead of
  `board.columns.inReview`. Renaming the column in config had no effect.
- Cards reached In Review but never In Progress. `board_ensure_item` added the
  card and then read the item list once to get its id, on the assumption that an
  add is immediately visible. Projects v2 is GraphQL-backed and it is not, so the
  read came back empty, the id was empty, and the move was skipped — while the
  In Review move forty minutes later worked, because by then the listing had
  caught up. The id now comes from `item-add --format json` where gh provides it,
  and falls back to a bounded retry (5 reads, ~15s) otherwise.
- A board that cannot move a card now says so on the run summary, as a warning
  annotation, instead of one `warn` inside a collapsed log group. Every board
  call is non-fatal by design; the cost was that "the card did not move" had no
  visible cause. `preflight` also states the board mode before it claims, so a
  run with no board configured says that in one line.

## 0.1.0 — 2026-08-19

First extraction from the repository this grew in.

- `npx avengers-12 init` copies the harness into a repository; `doctor` checks it
- Everything project-specific lives in one `config.yml`
- Claude Code permission rules are derived from `gate.deny`, not written twice
- Verified end to end against a Node project, which is not the kind of project
  it was written in

Known limits:

- The logic is bash and python. npm is delivery, not runtime.
- The runner needs `bash`, `jq` and `python3`. Windows runners are untested.
- One real consumer so far, plus the scratch project in `test/install.sh`.
