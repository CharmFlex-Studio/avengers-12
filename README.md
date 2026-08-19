# avengers-12

Board-driven issue implementation, as a folder you can lift into another repo.

Everything project-specific lives in `config.yml`. Nothing in `lib/` names a path, a build
command or a column that belongs to one repository — if you find one, that is a bug worth
reporting, because it is the thing that stops anyone else reusing this.

You start it, and you answer its questions. Everything between those two things is
automatic.

## Layout

```
.github/workflows/          the only files that cannot live in this folder.
  loop.yml                  GitHub reads workflows from here and nowhere else.
  loop-board-done.yml       They hold wiring, never logic.
  claude.yml

avengers-12/
  config.yml                EVERYTHING project-specific. Start here.
  README.md                 this file
  lib/                      the enforcement layer. Runs as workflow steps, never inside
                            the agent, and never asks a model whether a rule was followed.
  rules/                    constraints.md, budget.md — prose for the agent to read
  settings/                 implement.json, triage.json — tool permissions
  docs/setup.md             one-time setup
  state/                    STATE.md and run-log.md, written by runs

.claude/skills/, .claude/agents/     the agent contracts. Claude Code discovers them at
                                     these paths, so they cannot move into this folder yet.
```

## Checking an installation

```
avengers-12/lib/doctor.sh
```

It compares the things that must agree and fails when they do not: the gate denylist
against the write permissions, `branch.prefix` against the workflow that triggers on it,
`tests.directory` and `houseRules` against the filesystem, the evidence files the verifier
reads against the ones `evidence.sh` writes, config keys against whether anything reads
them, workflow defaults against whether they shadow the config, every script against
`bash -n`.

**It also runs on every loop run**, as the first step of the triage job, before credentials
are even checked. That is the point: a drift check nobody runs is the same problem as the
drift it looks for. An incoherent harness now refuses to start, in seconds, instead of
producing a confusing failure forty minutes later.

This exists because the harness's recurring bug was never a crash. It was a document
promising a rule that no code enforced — a 25-file cap while the gate allowed 100,
permission rules missing half the denylist, a test folder named in three files and present
in none. Every one of those was checkable, and nothing checked it.

## Active loops

| Pattern | Trigger | Autonomy | What it does |
|---|---|---|---|
| **Loop** | `Loop` (manual, one button) | L2 draft PR | Triage → pick the next ready issue → implement it → draft PR |
| **Resume** | your comment on a `loop:blocked` issue | L2 draft PR | Same as above, on that issue, continuing the branch it left behind |
| Review iteration | `@claude` on a PR | L2 | Answers your review comments on the PR's own branch |
| Board close-out | a loop PR is closed | — | Moves the card to Done on merge, back to Todo if it was closed unmerged |

`Loop` runs as two jobs. `triage` is read-only and always runs; `implement` runs only when
the picker finds an eligible issue, so an empty queue costs two minutes and nothing else.

## When a run gets stuck

It comments on the issue with a "What I need from you" line. **Reply to that comment.**
That is the whole procedure — the reply fires the workflow again, `pick-next.sh` clears
`loop:blocked` and restores `loop:ready` in bash, and the run continues on the same branch
with your answer in `.loop/answer.md`.

You do not click a label, move a card, or re-run a workflow. If you find yourself doing any
of those, something is broken and it is worth saying so.

The reply must come from someone with write access (OWNER / MEMBER / COLLABORATOR), on an
issue rather than a PR, and must not contain `@claude` — that phrase belongs to the
interactive workflow, and firing both would put two agents on one issue.

Because `issue_comment` workflows are read from the **default branch**, resume only works
once the harness is on `main`. That is the same single merge the dispatch buttons need.

Inputs, all optional:

| Input | Effect |
|---|---|
| `issue_number` | Work this issue and skip triage entirely |
| `mode: triage-only` | Rank the queue and stop before implementing |
| `base_branch` | Blank = the branch you selected in "Use workflow from" |
| `model` | `claude-opus-5` for genuinely hard issues |

Not on a schedule. Adding `schedule:` is one line once the run history justifies it.

## Who decides what gets worked on

Triage produces a ranked queue, and that ranking is model output — useful to read, not
something to obey. **`avengers-12/lib/pick-next.sh` makes the actual choice, in bash**, by
rules you can check by hand.

First it does the housekeeping nobody should have to do by hand:

- **releases stale claims** — an issue stuck on `loop:in-progress` behind a runner that
  died is cleared, once no other Loop run is in flight and the claim is older than
  `LOOP_STALE_CLAIM_HOURS` (default 2)
- **resumes answered issues** — a `loop:blocked` issue whose newest human comment is newer
  than its newest `<!-- loop-escalation -->` gets `loop:blocked` removed, `loop:ready`
  restored, and its card moved back to Todo

Then it picks:

1. issue is open
2. carries `loop:ready`
3. carries neither `loop:in-progress` nor `loop:blocked`
4. has no open pull request from `loop/issue-N` — that work is already done
5. order: **issues you just answered**, then the board's **Todo column order**, then the
   lowest issue number

The run summary prints the full shortlist alongside the pick, so the decision is auditable
rather than a black box. If you disagree with what it chose, drag the card in the board's
Todo column — that is what the ordering reads.

## The board

The board is the source of truth for *what order* work happens in and *where each item
stands*. Labels remain the source of truth for *whether* an issue may be worked at all —
which is why a broken board degrades the queue's ordering but can never stop the harness.

| Column | Set by |
|---|---|
| Todo | `pick-next.sh` when it resumes an answered issue or releases a stale claim; `loop-board-done.yml` when a PR is closed unmerged |
| In Progress | `preflight.sh`, when the run claims the issue |
| In Review | the `Push and open draft PR` step |
| Blocked | `escalate.sh` |
| Done | `loop-board-done.yml`, when the PR merges |

Every worked issue is added to the board automatically — `preflight.sh` calls
`gh project item-add` when the card does not exist yet, so nothing is worked on invisibly.
No column is ever moved by a model: `avengers-12/settings/triage.json` denies every
`gh project` write, so a card's position always reflects what a run did rather than what a
model believed.

## Which branch the loop works on

Work here happens on feature branches (`jiaming/transcription`, `feat/auto-translation`,
`ui/modern-refactor`), not on `main`, and the loop follows that.

Two different things are involved, and it's worth keeping them apart:

| | |
|---|---|
| **Where the workflow is read from** | The **"Use workflow from"** dropdown in the Actions tab. GitHub reads the workflow file from that branch and runs that version of it. |
| **What the loop builds on** | The same branch, by default. Override with the `base_branch` input if you want to dispatch a workflow from one branch but base the work on another. |

So to implement an issue on top of `jiaming/transcription`: pick that branch in the
dropdown, enter the issue number, run. The loop branches `loop/issue-N` from it, and the
draft PR targets it — `main` is never involved.

**One unavoidable exception.** GitHub only lists a `workflow_dispatch` workflow in the
Actions tab if the file exists on the repository's **default branch**. So the harness has
to be merged to `main` once, for the buttons to appear at all. After that single merge,
nothing else needs to touch `main`.

The base branch is **recorded on the branch itself**, as a `Loop-Base-Branch:` trailer on
an empty marker commit that `preflight.sh` makes when it creates `loop/issue-N`. If a
later run targets a different base, preflight reads that trailer and refuses rather than
stacking the change on unrelated history — it tells you to delete the stale branch or name
the base it came from. A branch created before this recording existed has no trailer;
preflight says so and reuses it unverified rather than stranding the work.

This is also what makes resume-by-comment work on feature branches. A comment-triggered run
starts on the default branch, because that is where GitHub reads the workflow from — so it
reads the trailer and re-bases itself onto the branch the work actually belongs to.

## The design in one line

**The model proposes, bash disposes.** Claude commits locally and cannot push. Every rule
that matters is a workflow step, not an instruction:

| Rule | Enforced by |
|---|---|
| Path denylist, diff size | `avengers-12/lib/check-gate.sh` + `avengers-12/config.yml` |
| Build and tests green | a gradle step that runs after the agent exits |
| No push, no self-editing | `avengers-12/settings/implement.json` deny rules, mirroring `avengers-12/config.yml` |
| Readiness, daily cap, kill switch | `avengers-12/lib/preflight.sh` |
| Correct base branch | the `Loop-Base-Branch:` trailer, read by `preflight.sh` |
| Max 3 fix attempts per run | `.loop/attempts.json`, written by `avengers-12/lib/evidence.sh` |
| Which issue gets worked, and in what order | `avengers-12/lib/pick-next.sh` |
| A reply resumes the work | the `issue_comment` trigger + `pick-next.sh` |
| A saved branch stays usable | `avengers-12/lib/strip-denied.sh` |
| Nothing disappears silently | `avengers-12/lib/escalate.sh` on `if: always()`, `preserve-work.sh` on `failure() \|\| cancelled()` |

## Agents

One Claude invocation per implement run, orchestrating three subagents:

| Agent | Role | Can |
|---|---|---|
| orchestrator (`loop-implement` skill) | state machine, artifact bus | sequence, package — not edit source, not overrule a verdict |
| `loop-implementer` | writes code | edit, compile — not commit, push, or spawn agents |
| `loop-verifier` | blocking judgment | read, run tests — not write anything |
| `kotlin-reviewer` | advisory quality notes | read — never blocks |

They cooperate through typed files in `.loop/`, never through conversation. The verifier is
given the evidence and the acceptance criteria and nothing else — never the implementer's
account of its own work.

## Honest limits

Five things are weaker than they look. Better to know than to be surprised:

- **The verifier could read the implementer's rationale.** `evidence.sh` moves
  `changes.md` out of the repo before VERIFY, but the verifier has `Bash` and could go
  looking. This raises the bar; it is not a hard boundary. Real isolation needs a separate
  filesystem view, which the action doesn't offer.
- **`main` is not protected by the harness.** The triage job commits `avengers-12/state/STATE.md` directly to
  `main` — that's the harness, not the agent, and the agent has no credential to do the
  same. Enable branch protection anyway; see `avengers-12/docs/setup.md`.
- **Permission deny rules are prefix matches.** `Bash(git push:*)` does not stop
  `git -C . push`. They are a second layer. The load-bearing controls are structural: no
  credential on the Claude step, and `check-gate.sh` reading the real diff afterwards.
  Where a whole verb can be denied, it is: triage denies `Bash(git:*)` outright, because it
  has no use for git. Note that deny beats allow, so you cannot deny a verb and allow one
  subcommand back.
- **`@claude` does not push through bash.** `claude.yml` loads `avengers-12/settings/implement.json`, which
  denies `git push` and every `gh` command. What it can still do is edit the working tree
  and write through the action's own GitHub integration. The workflow now resolves the pull
  request's head branch before checkout, so it is at least looking at the code under
  review — it used to check out the default branch and answer about the wrong tree. If you
  need a change pushed and it does not appear on the PR, do it by hand rather than assuming
  the workflow will.
- **Board ordering is the API's order, not a saved rank.** `gh project item-list` has no
  "position" field, so `pick-next.sh` uses the order the Todo column comes back in. It
  tracks the board closely in practice, but it is not a guarantee, and it is advisory by
  design: labels decide eligibility, the board only decides sequence.

## Human gates

- Draft PR only. You merge. The agent never pushes and cannot reach `main`.
- Escalations arrive as a comment on the source issue, with a mandatory "What I need from
  you" line naming the decision.
- Kill switch: set repo variable `LOOP_PAUSE_ALL=true`. Both workflows skip immediately.

## Configuration

Two places, and they answer different questions.

**`avengers-12/config.yml`** — what this project is. Paths, build commands, limits, column
names, models. Version-controlled, reviewed like code, and the only file you edit to move
the harness to another repository.

**Repo variables and secrets** — what this *installation* is. Things that must not be in
git, or that differ per environment.

Read `config.yml` before this list; almost everything now lives there.

| Where a value lives | Examples |
|---|---|
| `config.yml` | denylist, verify commands, test folders, house-rules documents, runtime and JDK, board columns, labels, branch prefix, caps, models, seed sources |
| Repo variables | board number and owner, kill switch |
| Repo secrets | tokens |

Repo **variables**: `LOOP_PROJECT_NUMBER`, `LOOP_PROJECT_OWNER`, `LOOP_PAUSE_ALL`,
optionally `LOOP_BOARD_OPTIONAL`.

`LOOP_BOARD_OPTIONAL` overrides `board.optional` in `config.yml`, which ships as `true`.
That default is deliberate: requiring the board used to fail the triage job — and, through
`needs:`, the implement job — so a board that had never been configured could stop the
entire harness. Set `board.optional: false` once your board resolves, to make a broken board
loud again.

The workflow passes these variables through **without a `|| default`**, on purpose. An
unset repository variable arrives as an empty string, which every script reads as "not
set" and falls back to `config.yml` for. Writing a default in `loop.yml` instead made the
variable always non-empty, so `budget.maxRunsPerDay` and `board.optional` were never read
at all — the file said 9 and the run still stopped at 4. `doctor.sh` now refuses that
shape.

Caps moved into `config.yml` under `budget:` — `maxRunsPerDay`, `maxAttemptsPerRun`,
`staleClaimHours`, `priorFilesMax`. Every one can still be overridden for a single run by
setting the matching `LOOP_*` environment variable, because environment wins over config in
`common.sh`. That is for debugging, not for configuration.

Repo **secrets**: `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token`, bills your
subscription), `LOOP_PROJECT_TOKEN` (fine-grained PAT — Projects v2 is invisible to both
`GITHUB_TOKEN` and the Claude GitHub App), optionally `LOOP_WEBHOOK_URL`.

## Scope

Two lists in `config.yml` decide it, and nothing else does:

- **`verify`** — what a change must pass. A directory covered by a verify step is in scope,
  including one behind a `when:` glob that only runs when the diff touches it.
- **`gate.deny`** — what a run may never touch. Everything a verify step cannot check
  belongs here, because a green run that verified nothing is worse than a refused one.

There is no third category. A path is checked or it is denied.

The gate runs on `ubuntu-latest`. A platform that needs a different runner is not covered,
and belongs on the denylist — `macos-latest` bills included Actions minutes at 10×, which
for this repository would cut roughly 375 runs a month to 28. Build the draft PR locally
before merging anything that touches code those platforms share.

## Files

Everything below lives in `avengers-12/` unless it says otherwise.

| Path | What it is |
|---|---|
| `config.yml` | the only file another project must edit |
| `lib/config.py` | parses `config.yml` into JSON; a small YAML subset, deliberately not PyYAML |
| `lib/doctor.sh` | checks that config, permissions, workflows and the filesystem agree |
| `lib/verify.sh` | runs the `verify:` steps; this is how a change proves itself |
| `lib/cache_key.py` | hashes `runtime.cacheKeyFiles`, because `hashFiles()` cannot read its globs from a file |
| `lib/check_config_used.py` | finds config keys nothing reads; a dead key looks configurable and is not |
| `lib/seed-board.sh` | one-time bootstrap: turns `seed.sources` checklists into issues |
| `lib/emit-config.sh` | publishes config values as workflow step outputs, because `${{ }}` cannot read a file |
| `lib/gate_check.py` | matches the diff against `gate.deny` |
| `lib/pick-next.sh` | chooses the issue; owns the stale sweep and the resume sweep |
| `lib/issue-state.sh` | the checkable facts: has a human answered, is that claim dead |
| `lib/strip-denied.sh` | keeps a saved branch free of gate-denied paths |
| `lib/recorded-base.sh` | reads and writes the `Loop-Base-Branch:` trailer |
| `rules/constraints.md` | the binding rules, and which are machine-enforced |
| `rules/budget.md` | caps and kill switch |
| `state/STATE.md` | the queue as of the last triage |
| `state/run-log.md` | one JSON entry per run |
| `docs/setup.md` | one-time setup checklist |
| `.claude/skills/loop-*`, `.claude/agents/loop-*` | the agent contracts, outside this folder because Claude Code discovers them there |

The unit test named by `tests.example` in `config.yml` is why `verify` being green means
something. Point it at a real test, or the build passes with nothing run.

## Moving this to another project

1. Copy `avengers-12/` and `.github/workflows/`.
2. Edit `config.yml`: `gate.deny`, `verify`, `tests`, `runtime`, `board.columns`.
3. Run `avengers-12/lib/doctor.sh` until it is quiet.
4. Set the repo variables and secrets above.

Step 3 is the one that catches the mistakes. Do not skip it.

Phases 2 and 3 of `workflow-refactor.md` turn this copy step into an npm package and a
15-line workflow. Until then, copying the folder is the install.
