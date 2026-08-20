# avengers-12

Write a GitHub issue. Get back a draft pull request.

You describe what you want and add a label. A GitHub Action picks the issue up, writes the
code, runs your tests, and opens a draft PR. If it can't work out what you meant, it stops
and asks on the issue. You reply, and it carries on.

It never merges anything. You review every pull request yourself.

```
  you                        avengers-12                    you
   │                              │                          │
  write an issue ───────────▶  reads it                      │
  add "loop:ready"             writes code                   │
   │                           runs your tests               │
   │                           opens a draft PR ──────────▶ review, merge
   │                              │
   │◀──── asks a question ──── stuck?
  reply on the issue ────────▶ carries on
```

## What you need

| | |
|---|---|
| A GitHub repo | see the note about organisations below |
| A Claude subscription | Pro or Max. Runs bill against it |
| Node 18 or newer | only to install. The harness itself is bash and python |
| About 20 minutes | mostly clicking through GitHub settings |

Your project can be anything: Gradle, Node, Go, Python, Rust. You tell it how to build and
test in one config file.

**About organisations.** If you want the GitHub Project board to work, the repo and the
board both need to belong to an organisation. The token permission that lets anything move
a card only appears under Organisation permissions. On a personal repo the token can read
the board but never move a card, and nothing will tell you why.

Creating an org is free and takes a minute:
<https://github.com/account/organizations/new>. Move the repo into it, then create the
board there.

You can also skip the board. `board.optional: true` is the default and the loop runs on
labels alone. A personal repo is fine for that, and you lose nothing except the card view.

## Setup

### 1. Copy the files in

In your project folder:

```bash
npx avengers-12 init
```

This copies files into your repo. It won't overwrite anything you've already edited.

### 2. Fill in the config

In Claude Code, same folder:

```
/setup-workflow
```

It reads your project, works out how you build and test, and writes
`avengers-12/config.yml`. Then it tells you which of the steps below are still outstanding.

No Claude Code? Edit `avengers-12/config.yml` by hand. Every line has a comment saying what
it wants. Then run `npx avengers-12 doctor` until it stops complaining.

### 3. Install the Claude GitHub App

<https://github.com/apps/claude> and install it on your repo.

### 4. Add two secrets

**Settings → Secrets and variables → Actions → Secrets tab**

First, get your Claude token:

```bash
claude setup-token
```

| Secret | Required? | What it is |
|---|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | **Yes** | What `claude setup-token` printed |
| `LOOP_PROJECT_TOKEN` | **Yes** | A GitHub token, made in the next step |
| `LOOP_WEBHOOK_URL` | No | Any URL that accepts a JSON POST. You get a message when a run stops and needs you |

For `LOOP_PROJECT_TOKEN`: **Settings → Developer settings → Personal access tokens →
Fine-grained tokens → Generate new token**

- Repository access: only this repo
- Repository permissions: **Contents**, **Issues**, **Pull requests**, all Read and write
- Using a board? Also **Organisation permissions → Projects → Read and write**

If your repo belongs to an org, set *Resource owner* to the org, not your username. An org
owner then has to approve the token. Until they do it works perfectly and sees nothing,
which is confusing enough to be worth checking first.

### 5. Add the variables

**Same page, Variables tab.** This is a different tab from Secrets and it's easy to miss.

| Variable | Required? | Value |
|---|---|---|
| `LOOP_PROJECT_NUMBER` | Only with a board | The number in your board's URL |
| `LOOP_PROJECT_OWNER` | Only with a board | The owner in your board's URL. The org, not your username |
| `LOOP_PAUSE_ALL` | No | `false`. Set it to `true` to stop every loop instantly |
| `LOOP_MAX_RUNS_PER_DAY` | No | Overrides `budget.maxRunsPerDay`. Leave it unset and the config wins |
| `LOOP_BOARD_OPTIONAL` | No | Overrides `board.optional`. Leave it unset and the config wins |

If you want a board and skip the first two, the board just sits there. Labels move, cards
don't, and nothing turns red. An unset variable looks exactly like "I don't want a board",
which is a normal way to run.

### 6. Merge to your default branch

Commit what `init` created and merge it to `main`.

GitHub only runs a workflow from the default branch when someone comments on an issue.
Until this is merged, replying to a question does nothing.

### 7. Check it

```bash
npx avengers-12 doctor
```

Fix what it names, then run it again. Keep going until it's quiet.

Longer version of all of this, with the org-owned cases spelled out:
[`docs/setup.md`](docs/setup.md).

## Your first run

**Write an issue.** Say what you want and how you'd know it worked:

```markdown
## Acceptance criteria
- [ ] An empty search box shows "Type to search" instead of a blank list
- [ ] A test covers the empty-input case
```

Those criteria are the whole spec the coder gets. Vague criteria give you vague code, or a
run that stops and asks what you meant.

Not sure the format is right? Check before you spend a run:

```bash
avengers-12/lib/check-issue.sh --issue 36
```

It uses the same parser as the gate, so it can't tell you something different.

**Add the label `loop:ready`.**

**Start a run.** GitHub → Actions → Loop → Run workflow.

Pick `triage-only` the first time. It reads your queue and tells you what it thinks without
spending a run. Read that before letting it write code.

Then run it again with `mode: full`. About 20 minutes later you get a draft PR.

## Using it

| To do this | Do this |
|---|---|
| Queue up work | Write an issue, label it `loop:ready` |
| Start a run | Actions → Loop → Run workflow |
| Answer a question | Reply on the issue. It restarts by itself |
| Stop everything | Set `LOOP_PAUSE_ALL` to `true` |
| See what it's thinking | `avengers-12/state/STATE.md`, rewritten every run |

### The labels

| Label | Means |
|---|---|
| `loop:ready` | Queued. It will pick this up |
| `loop:in-progress` | Being worked on right now |
| `loop:in-review` | Draft PR is open, waiting for you |
| `loop:blocked` | It asked you something and stopped |
| `loop:needs-spec` | Too vague to attempt. Add detail |

You only ever set `loop:ready`. The rest are the loop's.

### When it asks you something

It comments on the issue and stops. Reply in plain words. That's it. Your reply restarts it
and you don't need to touch the label.

One thing to avoid: don't write `@claude` in your reply. That phrase belongs to a different
workflow and your answer will go to the wrong place.

If it decides your reply doesn't count, it says so on the issue and explains why.

## What it won't do

These are deliberate.

- It never merges. Every PR is a draft.
- It never pushes to your default branch. Only to `loop/issue-N` branches.
- It can't edit its own rules. `config.yml`, the workflows and the scripts are all blocked.
- It stops and asks rather than guessing at a vague issue.
- It runs twice a day by default. Change `budget.maxRunsPerDay`.
- One run at a time. A second run waits for the first.
- An implement run is capped at 45 minutes.

After the coder finishes, and before anything is pushed, a script compares the changed
files against your denylist and runs your build and tests. It doesn't ask the agent whether
it behaved. It looks at the diff.

## When something goes wrong

| You see | It means |
|---|---|
| Red run at the first step | Setup isn't finished. Run `npx avengers-12 doctor` |
| `Invalid username or token` | The token isn't approved yet, or is missing a permission |
| Cards don't move on the board | Look at the top of the run summary. It says why now |
| Issue got `loop:needs-spec` | Too vague. Run `check-issue.sh` on it to see exactly why |
| Green run but nothing happened | Read the summary. It says what it decided |
| Nothing happens when you reply | The workflow isn't on your default branch yet (step 6) |

The run summary page is written to be read. Start there, not in the logs.

## Configuration

One file: `avengers-12/config.yml`. Nothing project-specific lives anywhere else.

The parts you'll actually touch:

```yaml
verify:                          # how a change proves itself
  - name: test
    run: npm test                # your real command

gate:
  deny:                          # paths a run must never touch
    - ".env"
    - "**/secrets/**"

tests:
  directory: test                # where new tests go
  example: test/example.test.js  # the style to copy

budget:
  maxRunsPerDay: 2
```

`verify` matters most. If that command doesn't really run your tests, then "tests passed"
means nothing, and every run goes green having checked nothing.

Everything else has a working default and a comment in the file explaining it.

## Commands

```bash
npx avengers-12 init      # copy the harness in. Safe to run again
npx avengers-12 doctor    # check the installation. 16 checks
npx avengers-12 version
```

```bash
avengers-12/lib/check-issue.sh --issue 36    # will this issue be accepted?
pbpaste | avengers-12/lib/check-issue.sh     # or paste the text
```

`init --force` refreshes the scripts and workflows. It never touches `config.yml` or your
run history, whatever flags you pass.

## Where it stands

Version 0.4.1. Early.

The logic is bash and python. npm is how it gets to your repo, not what runs it.

It's used daily on one Gradle project, and tested on every commit against a scratch Node
project. It needs `bash`, `jq` and `python3` on the runner, which `ubuntu-latest` has.
Windows runners are untested.

It came out of a real repo rather than being designed as a library. That's the reason to
trust it and the thing to watch: it does what one project genuinely needed.

Treat `config.yml` as stable and the rest as liable to change.

## More

- [`docs/setup.md`](docs/setup.md) — every setup step in full
- [`rules/constraints.md`](rules/constraints.md) — the rules a run follows, and which are
  enforced by code rather than asked for politely
- [`rules/budget.md`](rules/budget.md) — what a run costs
- [`CHANGELOG.md`](CHANGELOG.md)

What ends up in your repo after `init`:

```
avengers-12/
  config.yml       yours. The only file you have to edit
  lib/             the scripts. Run by GitHub Actions, never by the model
  rules/           what a run has to follow
  settings/        what the model is allowed to do
  docs/setup.md    the long version of steps 3 to 6
  state/           what happened. Written by the loop, read by you

.github/workflows/ loop.yml and loop-board-done.yml
.claude/           the skills and subagents Claude Code uses
```

MIT licensed. Issues and pull requests welcome:
<https://github.com/CharmFlex-Studio/avengers-12>
