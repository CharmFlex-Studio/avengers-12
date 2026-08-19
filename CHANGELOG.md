# Changelog

## 0.2.2 — 2026-08-19

- The advisory reviewer is a config key, `review.agent`, instead of
  `kotlin-reviewer` written into the implement skill. Every project in another
  language either got a review from an agent that did not understand its code,
  or silently got none — and the skill's own fallback said only "reviewer
  unavailable", which reads like a temporary glitch rather than "this stage does
  not apply to you". Empty means skip, and that is a supported choice.

- Fixed: an issue blocked by **triage** could never be resumed by replying. Two
  things set `loop:blocked` — `escalate.sh`, which posts an escalation comment,
  and triage, which sets the label from a verdict because a model is not allowed
  to escalate on its own. The resume check looked only for escalation comments,
  found none, and concluded there was no question to answer. It then refused
  every reply, permanently. Resume now dates replies against whichever came
  later: the escalation, or the moment the `loop:blocked` label was applied.
  Re-adding an existing label emits no new event, so that timestamp cannot drift
  forward underneath a reply.

- Fixed: replying to an escalation with GitHub's **Quote reply** left the issue
  blocked forever. Quote reply copies the raw markdown you are replying to, HTML
  comments included, so the reply contained `<!-- loop-escalation -->`. Two
  things then went wrong at once: the reply was filed as one of the loop's own
  comments, *and* it became the newest escalation — so the answer was compared
  against itself and always lost. Every further reply landed in the same hole.
  All three marker tests now strip quoted lines first, through one shared jq
  expression rather than three copies.

- `check-board.sh` now tests whether the token can WRITE, not just read. Every
  check before this was a read, and a read-only token passes all of them — which
  is how a board sails through setup and then refuses every move at run time,
  once per card, inside a job log nobody opens until the board looks wrong. The
  test is a no-op write: it sets some card's Status to the value it already has.
  GitHub still requires the write permission for that, so it proves access
  without moving anything.

- Board failures now print what GitHub actually said. `item-edit` and `item-add`
  sent stderr to /dev/null and a guess was printed in its place — "the token
  needs Projects: Read and write" — which is the commonest cause and not the
  only one. A specific-sounding wrong guess sends people to audit the wrong
  thing, and there was no way to tell it apart from the right one, because the
  evidence had been thrown away.

- Fixed: `sync-board.sh` reported "moved 4 of 5" in a run where every write was
  refused. It counted attempts, because `board_set_status` always returns 0 by
  design — a broken board must not fail a run — so a caller had no way to tell a
  move from a refusal. It now publishes `BOARD_LAST_MOVE_OK`, the counter reads
  it, and a run with failures says so instead of contradicting its own warnings.

- The board setup shipped a default that does not match GitHub's. `board.columns`
  names five lanes; a new GitHub Project has three. `In Review` and `Blocked` had
  to be added by hand, the docs said so in prose halfway down a long section, and
  the failure was a warning in a job log. So a new board would move cards to In
  Progress and then stop, with nothing turning red. It is now stated in
  `templates/config.yml` next to the five names, at the top of the board section
  of `docs/setup.md`, and by `check-board.sh`, which prints the click-path and
  says plainly that this is expected on a new board rather than something you got
  wrong.

- Fixed: `sync-board.sh` read its issue list on stdin while shelling out to `gh`
  on every iteration. Anything inside that reads stdin swallows the rest of the
  queue, so the loop would reconcile the first issue and stop — silently, looking
  exactly like a board that only sometimes updates. It reads on fd 3 now.

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
