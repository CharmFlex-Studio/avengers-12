# Changelog

## 0.2.2 — 2026-08-19

- Fixed: `doctor`'s board check reported a working board as unreadable. The
  Doctor step in `loop.yml` had no `GH_TOKEN`, so `gh project view` ran with no
  credential and failed the same way a broken board does. It now has the token.
- `check-board.sh` no longer blames the board for a missing credential. It
  checks whether `gh` is installed and authenticated first, and says so — a
  check that misdiagnoses sends you to audit your token scopes and your org
  approval when the real answer is that the step was never given a token.

- `lib/check-issue.sh` — tells you whether an issue will pass preflight, before
  you spend a run finding out. `--issue N` fetches it, or pipe the text in. It
  names the two rules people miss: the heading must contain the words
  "acceptance criteria" in that order (`AC` does not match), and every criterion
  needs a list marker, because the verifier judges "does the diff satisfy item
  3?" and a paragraph has no item 3.
- The acceptance-criteria parser moved into `common.sh` as `acceptance_items()`,
  shared by preflight and the new checker. Two copies would drift, and then the
  tool saying "your issue is fine" would be describing a different rule from the
  gate that rejects it.

## 0.2.1 — 2026-08-19

The board now tells the truth. Every card move in this harness is paired with a
bash step that changes a label; three of those pairs were broken, and all three
failed silently because board operations are non-fatal by design.

- Cards reached In Review but never In Progress. `board_ensure_item` added the
  card, then read the item list once to get its id, assuming an add is
  immediately visible. Projects v2 is GraphQL-backed and it is not: the read
  came back empty, the id was empty, and the move was skipped. The In Review
  move forty minutes later worked, because by then the listing had caught up —
  which is exactly what it looks like from the outside. The id now comes from
  `item-add --format json`, with a bounded retry (5 reads, ~15s) as a fallback.
- `loop.yml` moved cards to a hardcoded `"In Review"` instead of
  `board.columns.inReview`. Renaming that column in config had no effect.
- `lib/sync-board.sh`, run by the triage job — reconciles every card's lane with
  the labels on its issue. Two things changed labels and moved no card: triage,
  which works through a model and is deliberately not allowed to drive the board,
  and a human clicking a label in the GitHub UI, which nothing here is triggered
  by at all. It reads the labels as they stand and moves whatever disagrees, so
  it is safe at any point and safe to run twice.
- `lib/check-board.sh`, run by `doctor` — verifies the board resolves and that
  every column in `board.columns` exists on it. A default GitHub Project ships
  with Todo, In Progress and Done only, so In Review and Blocked silently did
  nothing on a fresh board.
- A board that cannot move a card now says so on the run summary as a warning,
  instead of one `warn` inside a collapsed log group. `preflight` states the
  board mode before it claims, so a run with no board says that in one line.
- `doctor` fails when a script in `lib/` has no caller anywhere. That is how
  `sync-board.sh` sat complete and wired to nothing: dead code that looks alive
  is worse than missing code, because you read the directory and assume the job
  is done.

## 0.2.0 — 2026-08-19

Setup no longer starts at a blank config file.

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
