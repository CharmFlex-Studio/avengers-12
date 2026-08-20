---
name: setup-workflow
description: >
  Set up the avengers-12 loop in this repository: write config.yml from what the project
  actually is, create the labels, and hand back the exact browser steps only a human can do.
  Run it once after `npx avengers-12 init`, and again any time `doctor` complains.
allowed-tools: Read, Grep, Glob, Edit, Write, Bash
user_invocable: true
---

# Setting up the loop

Your job is to get `avengers-12/lib/doctor.sh` to exit 0 and leave the owner with a short,
correct list of the things only they can do.

**Half of this setup happens in a browser and cannot be automated.** Installing a GitHub
App, minting a fine-grained token, creating a Projects board — none of that has an API you
can drive from here. Do not pretend otherwise, do not "simulate" it, and do not tell the
owner a step is done because you wrote it down. Say plainly which steps are theirs.

## Read the ground truth first

Run both. They report facts and change nothing:

```bash
avengers-12/lib/detect-project.sh    # what kind of project this is
avengers-12/lib/setup-status.sh      # which setup steps already left their trace
```

If `detect-project.sh` reports `isGitRepo: false`, stop. The harness works on the diff
between commits; there is nothing for it to do here yet.

## 1. Write `config.yml`

This is the part worth your attention. Everything else is mechanical.

`avengers-12/config.yml` was copied from a template full of placeholders. Replace them
using what you detected **and what you read in the repository** — open the build files,
open a test, look at how the project is actually laid out. Do not fill it in from the
detector's output alone; the detector reports facts, not decisions.

Four keys matter more than the rest:

**`verify`** — how a change proves itself. Take the real commands, the ones a contributor
runs before pushing. Check `package.json` scripts, the CI workflows already in
`.github/workflows/`, the README, the Makefile. A wrong command here is the worst possible
error: every run goes green having proved nothing.
- `nestedBuilds` from the detector means a second build with its own directory. Give it its
  own step with `workingDirectory` and a `when:` glob, or that half of the repo is never
  built.

**`gate.deny`** — what a run may never touch. Start from the template's list, then add:
- every path in `secretsTracked` and `secretsIgnored`
- anything no `verify` step covers. A directory that nothing builds and nothing tests must
  be denied, or a run can change it and still go green.

**`tests.directory` and `tests.example`** — where tests live, and one real test to copy the
style from. `tests.example` must be a file that exists; the coder reads it before writing
its first test. Pick a small, clear one, not the biggest.
- Any path in `testPaths` that your `verify` commands do **not** run belongs in
  `tests.notRun`, so the coder is told rather than finding out at the gate.

**`permissions.allowBash`** — the build and test commands the coder is allowed to run.
Match the tools in `verify`.

Also set `runtime.java` if this is a JVM project, and leave it out if not — the JDK setup
step is skipped when it is unset.

When you have written it:

```bash
avengers-12/lib/doctor.sh
```

Fix what it reports and run it again. Keep going until it is quiet. **Do not move on with
doctor red**, and do not edit doctor to make it pass.

## 2. The board, if they want one

```bash
avengers-12/lib/check-board.sh
```

It exits 0 and says so when no board is configured — label mode is a supported way to
run, and `board.optional: true` ships as the default. Do not push anyone towards a board.

**Ask first whether the repository is owned by an organisation.** A fine-grained token gets
`Projects: Read and write` through *Organisation* permissions, so a personally-owned repo
cannot move cards — it can read the board and every check here passes, because every check
is a read. Say that before they spend twenty minutes building a board they cannot drive.
Creating an org is free; so is deciding not to and running on labels.

When a board **is** configured, this is the check that matters, because every board
operation in the harness is deliberately non-fatal. A card that cannot move produces one
warning inside a job log and nothing else: the run stays green, the card stays put, and
the owner finds out days later by looking at the board.

The failure it catches most often: **a default GitHub Project has only Todo, In Progress
and Done.** There is no In Review and no Blocked. The loop then tries to move cards into
two lanes that do not exist — including, at the worst moment, the Blocked lane an
escalation depends on.

This is not a mistake the owner made. GitHub has no way to ship those two lanes, and this
harness will not edit anyone's board for them. Say that plainly — someone told "your board
is missing columns" on day one reasonably assumes they set it up wrong.

Two ways to fix it, and the owner picks:
- **add the options**: open the board, click any card, click the Status field, Edit options
  → New option, once per missing name
- **or rename `board.columns`** in `config.yml` to whatever their board already calls them

Put it on the checklist in section 4 as a browser step, because that is what it is. Do not
report the board as working until `check-board.sh` is quiet.

## 3. Labels

Only when `gh` reports authenticated. Create whatever `setup-status.sh` lists as missing:

```bash
gh label create "loop:ready"       --color 0E8A16 --description "Verified implementable unattended"
gh label create "loop:in-progress" --color FBCA04 --description "Claimed by a loop run"
gh label create "loop:in-review"   --color 1D76DB --description "Draft PR open"
gh label create "loop:blocked"     --color B60205 --description "Escalated — needs a human decision"
gh label create "loop:needs-spec"  --color 5319E7 --description "Not implementable as written"
```

Use the names from `config.yml`, not these, if the owner changed the `labels:` section.
Adding a label that already exists is an error; skip the ones already present.

## 4. Report what only the owner can do

Finish with a checklist of the browser steps, in order, marked with what you could verify.
Keep it short and specific. Point at `avengers-12/docs/setup.md` for the detail rather than
repeating it.

The steps, and how to tell whether each is done:

| Step | Done when | You can check it? |
|---|---|---|
| Install the Claude GitHub App | the app appears in the repo's settings | no |
| `CLAUDE_CODE_OAUTH_TOKEN` secret | `secrets` includes it | yes, via `setup-status.sh` |
| Fine-grained PAT, saved as `LOOP_PROJECT_TOKEN` | `secrets` includes it | yes, name only — never the value |
| Projects v2 board, if wanted | `variables` include `LOOP_PROJECT_NUMBER` and `LOOP_PROJECT_OWNER` | yes |
| Workflows merged to the default branch | `workflowsOnDefaultBranch: true` | yes |

Two things to say out loud, because they are the ones that waste an afternoon:

- **The board is optional.** `board.optional: true` ships as the default and the loop runs
  on labels alone. Do not let a board block the first run.
- **`issue_comment` only ever runs the workflow from the default branch.** Until
  `loop.yml` is merged there, replying to a blocked issue does nothing at all. If
  `workflowsOnDefaultBranch` is false, this is the most important item on the list.

## 5. Offer the first run, do not take it

Tell the owner the first thing to try, and let them press it:

> Actions → Loop → Run workflow, `mode: triage-only`. Read the output before spending a
> full run — triage is read-only and unmetered; an implement run costs one of the day's
> slots.

## What you must not do

- Do not write a token, a PAT, or any secret value into a file, a command, or the
  transcript. If the owner pastes one, use `gh secret set NAME` reading from stdin, and
  never echo it.
- Do not run the loop. This skill sets it up; the owner starts it.
- Do not edit `doctor.sh`, `gate_check.py`, or anything else under `avengers-12/lib/` to
  make a check pass. If a check is wrong, say so and leave it failing.
- Do not claim a browser step is complete. You cannot see them. Report what
  `setup-status.sh` returns and nothing more.
