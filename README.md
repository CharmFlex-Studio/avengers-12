# avengers-12

**Give Claude a GitHub issue. Get back a draft pull request.**

You write an issue and label it. A GitHub Action picks it up, writes the code, runs your
tests, and opens a draft PR. If it gets confused, it stops and asks you a question on the
issue. You reply, and it carries on.

It never merges anything. You review every pull request, as usual.

```
     you                          avengers-12                       you
      │                                │                             │
  write an issue  ──────────────▶  reads it                          │
  label it "loop:ready"            writes the code                   │
      │                            runs your tests                   │
      │                            opens a draft PR  ──────────────▶ review & merge
      │                                │
      │◀── asks a question ────────  stuck?
   reply on the issue  ───────────▶ carries on
```

---

## Before you start

You need all four:

| | |
|---|---|
| A **GitHub repository** | public or private, your own or your org's |
| A **Claude subscription** | Pro or Max. Runs bill against it |
| **Node 18+** | only to install. The harness itself is bash and python |
| **20 minutes** | most of it clicking around GitHub settings |

Your project can be anything — Gradle, Node, Go, Python, Rust. You tell it how to build and
test in one config file.

---

## Setup

### Step 1 — copy the files in

In your project folder:

```bash
npx avengers-12 init
```

This copies files into your repo. It never overwrites anything you have already changed.

### Step 2 — let Claude Code fill in the config

In Claude Code, in the same folder:

```
/setup-workflow
```

It looks at your project, works out how you build and test it, and writes
`avengers-12/config.yml`. Then it tells you which of the steps below are still outstanding.

*No Claude Code? Edit `avengers-12/config.yml` by hand instead — every line has a comment
saying what it wants. Then run `npx avengers-12 doctor` until it stops complaining.*

### Step 3 — the browser steps

These four cannot be automated. Nothing can do them for you.

**3a. Install the Claude GitHub App** — <https://github.com/apps/claude>, install it on your
repository.

**3b. Get your Claude token.** In a terminal:

```bash
claude setup-token
```

Copy what it prints. In GitHub: **Settings → Secrets and variables → Actions → Secrets →
New repository secret**

- Name: `CLAUDE_CODE_OAUTH_TOKEN`
- Value: the token you just copied

**3c. Make a GitHub token.** **Settings → Developer settings → Personal access tokens →
Fine-grained tokens → Generate new token**

- Repository access: only this repository
- Repository permissions: **Contents**, **Issues**, **Pull requests** — all Read and write
- If a **board** is wanted: also Projects → Read and write

Save it as a second repository secret named `LOOP_PROJECT_TOKEN`.

> **If your repo belongs to an organisation:** set *Resource owner* to the organisation, not
> your username. Then an org owner has to **approve** the token. Until they do, it works
> perfectly and sees nothing — which is confusing enough that it is worth checking first.

**3d. Merge to your default branch.** Commit what `init` created and merge it to `main`.

GitHub only runs workflows from the default branch when someone comments on an issue. Until
this is merged, replying to a question does nothing at all.

### Step 4 — check it

```bash
npx avengers-12 doctor
```

Fix whatever it names. Run it again. Keep going until it is quiet.

Full detail on every step, including screenshots' worth of specifics:
[`docs/setup.md`](docs/setup.md).

---

## Your first run

**1. Write an issue.** A title, what you want, and how you would know it worked:

```markdown
## Acceptance criteria
- [ ] Empty search box shows "Type to search" instead of a blank list
- [ ] A test covers the empty-input case
```

Acceptance criteria are not paperwork. They are the whole specification the coder gets.
Vague criteria produce vague code, or a run that stops and asks you what you meant.

**2. Label it `loop:ready`.**

**3. Start a run.** GitHub → **Actions** → **Loop** → **Run workflow**.

Pick `triage-only` the first time. It reads your queue and tells you what it thinks,
without spending a run. Read that before letting it write code.

**4. Then run it for real.** Same button, `mode: full`. About 20 minutes later you get a
draft PR.

---

## Day to day

| You want to | Do this |
|---|---|
| Queue up work | Write an issue, label it `loop:ready` |
| Start a run | Actions → Loop → Run workflow |
| Answer a question | Reply on the issue. It restarts by itself |
| Stop everything | Set the repo variable `LOOP_PAUSE_ALL` to `true` |
| See what it thinks | `avengers-12/state/STATE.md`, rewritten every run |

### The labels

| Label | Means |
|---|---|
| `loop:ready` | Queued. It will pick this up |
| `loop:in-progress` | Being worked on right now |
| `loop:in-review` | Draft PR is open, waiting for you |
| `loop:blocked` | It asked you something and stopped |
| `loop:needs-spec` | Too vague to attempt. Add detail |

**You never set these by hand.** Except `loop:ready` — that one is how you say "go".

### When it asks you a question

It comments on the issue and stops. Reply in plain words.

That is all. Your reply restarts it automatically. Do not change the label.

**One trap:** do not write `@claude` in your reply. That phrase belongs to a different
workflow and your answer will go to the wrong place. Just answer normally.

---

## What it will not do

Deliberate limits, not missing features:

- **It never merges.** Every PR is a draft. You review and merge.
- **It never pushes to your default branch.** Only to `loop/issue-N` branches.
- **It cannot edit its own rules.** `config.yml`, the workflows and the harness scripts are
  blocked. A run that could widen its own permissions would make every other rule pointless.
- **It stops rather than guesses.** A vague issue gets a question, not an invented answer.
- **It runs twice a day by default.** Change `budget.maxRunsPerDay` in `config.yml`.
- **One run at a time.** A second run queues behind the first.

Whatever it changes is checked *after* it finishes and *before* anything is pushed: the
files it touched are compared against your denylist, and your own build and tests must
pass. It is never asked whether it behaved. The diff is inspected.

---

## When something goes wrong

| What you see | What it means |
|---|---|
| Run is red at the first step | Setup is incomplete. Run `npx avengers-12 doctor` |
| `Invalid username or token` | The fine-grained token is not approved yet, or lacks a permission |
| Card does not move on the board | Look at the top of the run summary — it now says why |
| Issue got `loop:needs-spec` | Too vague to attempt. Add acceptance criteria |
| Run green but nothing happened | Read the summary. It says what it decided and why |
| Nothing happens when you reply | The workflow is not on your default branch yet (step 3d) |

The run summary page is written for you to read. Start there, not in the logs.

---

## Configuration

One file: `avengers-12/config.yml`. Nothing project-specific lives anywhere else.

The parts you will actually touch:

```yaml
verify:                              # how a change proves itself
  - name: test
    run: npm test                    # your real command

gate:
  deny:                              # paths a run may never touch
    - ".env"
    - "**/secrets/**"

tests:
  directory: test                    # where new tests go
  example: test/example.test.js      # the style to copy

budget:
  maxRunsPerDay: 2
```

`verify` is the one that matters most. If your command does not actually run your tests,
then "tests passed" means nothing and every run goes green having proved nothing.

Everything else — labels, branch names, board columns, models, caps — has a working default
and a comment in the file explaining it.

---

## Commands

```bash
npx avengers-12 init      # copy the harness in (safe to re-run)
npx avengers-12 doctor    # check the installation, 14 checks
npx avengers-12 version
```

`init --force` refreshes the scripts and workflows to the current version. It never touches
`config.yml` or your run history, whatever flags you pass.

---

## Honest status

**Version 0.2.1. Early.**

- The logic is bash and python. npm is how it reaches your repo, not what runs it.
- Used daily on one Gradle project. Tested on every commit against a scratch Node project.
- Needs `bash`, `jq` and `python3` on the runner. `ubuntu-latest` has all three. Windows
  runners are untested.
- Extracted from a real repository rather than designed as a library. That is the reason to
  trust it and the thing to watch: it does what one project genuinely needed.

Treat `config.yml` as stable and everything else as liable to change.

---

## Reference

- [`docs/setup.md`](docs/setup.md) — every setup step in full
- [`rules/constraints.md`](rules/constraints.md) — the rules a run must follow, and which
  are enforced by code rather than asked for politely
- [`rules/budget.md`](rules/budget.md) — what a run costs and where the caps live
- [`CHANGELOG.md`](CHANGELOG.md)

### What is in your repo after `init`

```
avengers-12/
  config.yml         yours. The only file you must edit
  lib/               the scripts. Run by GitHub Actions, never by the model
  rules/             what a run must follow
  settings/          what the model is allowed to do
  docs/setup.md      the long form of step 3
  state/             what happened. Written by the loop, read by you

.github/workflows/   loop.yml and loop-board-done.yml
.claude/             the skills and subagents Claude Code uses
```

MIT licensed. Issues and pull requests welcome:
<https://github.com/CharmFlex-Studio/avengers-12>
