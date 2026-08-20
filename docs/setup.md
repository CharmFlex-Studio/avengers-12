# Loop Harness — Setup

One-time setup. Steps 1–4 need your browser and GitHub account; nothing in the repo can do
them for you. Budget about twenty minutes.

Until this is done the workflows exist but every run fails at the first step, which is the
intended behaviour — the harness fails closed.

> **There is a shortcut for the parts that are not browser work.** In Claude Code, run
> `/setup-workflow`. It writes `config.yml` from what your project actually is, creates the
> labels, and tells you which of the steps below are still outstanding. It cannot do the
> browser steps — nothing can — so read on for those.

> **Two placeholders run through this guide.** `YOUR-ORG` is whoever owns the repository —
> an organisation, or your own username. `YOUR-REPO` is the repository itself. Every other
> name, path and setting is literal: type it exactly as written.
>
> The org-owned case is spelled out in full because it is where people get stuck. If you
> own the repository personally, read `YOUR-ORG` as your username and skip the approval
> step in section 3.

---

## 1. Install the Claude GitHub App

<https://github.com/apps/claude> → install on `YOUR-ORG/YOUR-REPO`.

You need admin on the repo. The app's permission set is all-or-nothing; the loop uses
Contents, Issues and Pull requests.

## 2. Subscription token

```bash
claude setup-token
```

Copy the output into a repository **secret** named `CLAUDE_CODE_OAUTH_TOKEN`
(Settings → Secrets and variables → Actions → New repository secret).

This bills runs against your Pro/Max subscription rather than API credits. The token is tied
to whoever ran the command.

## 3. Projects PAT

Projects v2 is invisible to both `GITHUB_TOKEN` and the Claude GitHub App, so the board
needs its own credential.

**If the repository belongs to an organisation**, three things change that people usually
get wrong. (Personally-owned repository? Read `YOUR-ORG` as your username, and the approval
step at the end of this section does not apply to you.) Settings → Developer settings → Personal access tokens →
**Fine-grained tokens** → Generate:

- **Resource owner: `YOUR-ORG`** — the organisation, *not* your personal account. A token
  owned by your account cannot see org repos at all, no matter its permissions.
- **Repository access**: only `YOUR-REPO`
- **Organisation permissions** → **Projects: Read and write** — for an org-owned board this
  is the right place. The *Account*-level Projects permission covers only boards you own
  personally, and grants nothing here.
- **Repository permissions** → Contents: Read and write · Issues: Read and write ·
  Pull requests: Read and write

Then the step that has no equivalent for personal repos:

> **An org owner must approve the token.**
> `YOUR-ORG` → Settings → Personal access tokens → Pending requests.
>
> Until approved, the token authenticates perfectly and sees nothing. That combination is
> what produces `Invalid username or token` at push time even though everything else in the
> run appeared to work.

Save as secret `LOOP_PROJECT_TOKEN` on the repository.

`avengers-12/lib/check-auth.sh` runs first in both workflows and tells you which of these is
wrong, in seconds, before a Claude run is spent.

## 4. The board

> **This whole step needs an organisation.** A fine-grained token gets
> **Projects: Read and write** through *Organisation permissions*, so the repository and the
> board must both be owned by an org — not by you personally. With a personal repo the token
> can read the board and will never move a card, and every check in this harness passes
> because every one of them is a read.
>
> Free, one minute: <https://github.com/account/organizations/new>. Then transfer the repo
> into the org and create the board under the org.
>
> **Not worth it for you?** Skip this section. `board.optional: true` is the default and the
> loop runs on labels alone — the same behaviour, tracked on the issues list.

Create a Projects v2 board, then **add two columns to it**.

> **A new GitHub Project gives you three: `Todo`, `In Progress`, `Done`.**
> The loop needs five. You have to add `In Review` and `Blocked` by hand — GitHub
> has no way to ship them and this harness will not edit your board for you.
>
> Click any card → the **Status** field → **Edit options** → **New option**.

The full set, and the names must match exactly:

```
Todo · In Progress · In Review · Blocked · Done
```

Skipping this is the single most common way to end up with a board that looks broken:
cards reach In Progress and then stop, because the next two lanes do not exist. Nothing
turns red — a missing lane is a warning, not a failure, because a tracking surface must
never fail a run that is otherwise fine. `npx avengers-12 doctor` names any that are
missing.

The names must match — `avengers-12/lib/board.sh` looks them up by name and warns (rather than
fails) when it can't find them, so a typo shows up as cards that never move. **Blocked** is
the newest of the five: `escalate.sh` puts a card there when a run stops and asks you a
question, so a blocked item stops masquerading as available work in Todo.

Who moves what, so you can tell a bug from normal behaviour — no column is ever moved by a
model:

| Column | Set by |
|---|---|
| Todo | `pick-next.sh` on resume or stale release; `loop-board-done.yml` on an unmerged close |
| In Progress | `preflight.sh` |
| In Review | the `Push and open draft PR` step |
| Blocked | `escalate.sh` |
| Done | `loop-board-done.yml`, on merge |

You do not have to add issues to the board yourself. `preflight.sh` calls
`gh project item-add` for any issue it works on that is not there yet.

### Reading the board number and owner

Both come from the board's URL, and **the URL is the only thing that settles it** — not
where you clicked "New project" from:

```
github.com/orgs/<owner>/projects/<number>    ->  LOOP_PROJECT_OWNER = <owner>  (an organisation)
github.com/users/<owner>/projects/<number>   ->  LOOP_PROJECT_OWNER = <owner>  (a person)
```

The board's owner and the repository's owner must be **the same**. Step 3's fine-grained
PAT is scoped to exactly one resource owner, so a personal board plus an org repo cannot
both be reached by one token. If your board URL says `/users/` and your repository belongs
to an org, either transfer the board to the organisation or accept label-only mode
(`board.optional: true`, which is the shipped default).

## 5. Repository variables

Settings → Secrets and variables → Actions → **Variables** tab:

| Variable | Value |
|---|---|
| `LOOP_PROJECT_NUMBER` | the number from step 4 |
| `LOOP_PROJECT_OWNER` | `YOUR-ORG` — the owner of the *board*, which for an org-owned board is the org, not your username. Read it off the board's URL, as in step 4. |
| `LOOP_PAUSE_ALL` | `false` — set to `true` to stop every loop instantly |
| `LOOP_MAX_RUNS_PER_DAY` | optional. Leave it unset and `budget.maxRunsPerDay` in `avengers-12/config.yml` applies. Set it only to override the config for a while. |
| `LOOP_BOARD_OPTIONAL` | optional. Leave it unset and `board.optional` in `avengers-12/config.yml` applies, which ships as `true`. Set `board.optional: false` once the board resolves, so a board that breaks later fails loudly instead of silently degrading to label-only ordering. |

Both are overrides, not settings. The config file is where the value belongs; an unset
variable is the normal state.

## 6. Labels

```bash
gh label create "loop:ready"       --color 0E8A16 --description "Verified implementable unattended"
gh label create "loop:in-progress" --color FBCA04 --description "Claimed by a loop run"
gh label create "loop:in-review"   --color 1D76DB --description "A loop draft PR is open and waiting for review"
gh label create "loop:blocked"     --color B60205 --description "Escalated — needs a human decision"
gh label create "loop:needs-spec"  --color D4C5F9 --description "Idea is fine, acceptance criteria are not"
gh label create "loop:discovered"  --color BFDADC --description "Problem the loop found while doing something else"
gh label create "loop:dashboard"   --color C5DEF5 --description "The pinned Loop Queue issue"
```

`loop:in-review` is the one that keeps a finished issue finished. On success the harness
strips `loop:ready` and applies it; without that the issue — still open, because `Closes #N`
fires only on merge — gets picked again on the very next run and the work is redone.

The scripts create any label they need if it is missing, so this step is a convenience
rather than a prerequisite. Run it anyway: you get the colours and descriptions.

## Running the loop on a feature branch

You develop on feature branches, and the loop does too. Pick the branch in the Actions tab's
**"Use workflow from"** dropdown — the loop bases `loop/issue-N` on it and targets the draft
PR at it. Set the optional `base_branch` input only when you want to dispatch from one
branch but build on another.

The one thing that must live on `main`: GitHub lists a `workflow_dispatch` workflow only if
the file exists on the **default branch**. Merge the harness there once and the buttons
appear; after that nothing else needs to touch `main`. Step 1 above is that merge.

## 7. Protect `main`

Settings → Branches → Add rule for `main`: require a pull request before merging.

This is not optional decoration. The loop's safety story is "the agent never reaches
`main`", and that holds because the agent has no credential — but the *harness* pushes
`avengers-12/state/STATE.md` to `main` from the triage job, and you want a review gate under everything
regardless. With protection on, that push is rejected and triage says so in a warning
rather than failing; the queue still lands in the Loop Queue issue, which is the copy you
actually read.

## 8. Install `gh` locally

```bash
brew install gh && gh auth login
```

Needed for the bootstrap script and for reading run logs when something goes wrong.

---

## Verify the install

Run these in order. Each is cheap, and each proves one layer before the next one costs
anything.

**The gate rejects what it should** (no setup required, works right now):

```bash
printf 'local.properties\n.claude/settings.local.json\n' > /tmp/bad.txt
python3 avengers-12/lib/gate_check.py avengers-12/config.yml /tmp/bad.txt   # expect exit 1, two violations

printf 'src/main/Foo.kt\n' > /tmp/ok.txt   # any path a verify step covers
python3 avengers-12/lib/gate_check.py avengers-12/config.yml /tmp/ok.txt    # expect exit 0, silent
```

**Triage runs** — Actions → Loop → Run workflow with `mode: triage-only`. Expect `avengers-12/state/STATE.md` rewritten with a
ranked queue, labels applied, the Loop Queue issue updated, under three minutes.

Read the readiness verdicts and decide whether you agree with them. That, not the ranking,
is the signal telling you whether your issues are written well enough to implement.

**The verify steps do something** (no setup required, works right now):

```bash
avengers-12/lib/verify.sh          # runs every step in config.yml, in order
```

That matters more than it looks. A test task passes happily against zero tests, and a
verifier checking "are the tests green?" against an empty run is checking nothing. So also
confirm `tests.directory` in `config.yml` actually holds tests, and that the verify commands
really run them — `doctor.sh` checks the first half, and only you can check the second.

Anything under `tests.notRun` never runs in the gate. List those directories there so the
coder is told plainly, instead of finding out when the verifier refuses its evidence.

**Implement runs** — pick the smallest `loop:ready` issue. Expect a `loop/issue-N` branch, a
draft PR, a green gate, the card in In Review, the issue relabelled from `loop:ready` to
`loop:in-review`, one run-log entry.

**The resume test**, which is the one the whole design turns on:

1. Find a `loop:blocked` issue with an escalation comment on it (or block one by cancelling
   a run against it).
2. Reply to that comment, as yourself, without writing `@claude`.
3. Expect: a `Loop` run starts within a minute of the comment; its summary says
   `#N was answered`; `loop:blocked` is gone and `loop:ready` is back; the card is out of
   Blocked; the implement job runs on the same `loop/issue-N` branch and the coder is
   handed `.loop/answer.md`.

You should not have touched a label, a card, or the Actions tab. If you did, that is the
bug.

Two things stop this firing, both on purpose: a comment containing `@claude` (that belongs
to the interactive workflow) and a comment from someone without write access.

**Then the negative tests**, which are what actually prove the harness:

| Test | Expected |
|---|---|
| Fire Implement on an issue without `loop:ready` | preflight fails, Claude never starts, zero spend |
| Set `LOOP_PAUSE_ALL=true`, fire either workflow | job skipped entirely |
| Add a path you're touching to `avengers-12/config.yml`'s denylist, re-run | fails at the gate, no branch pushed, patch in the artifact |
| Re-run an issue that already has an open loop PR | the picker skips it; a *named* re-run pushes to the existing PR and succeeds, rather than dying on "a pull request already exists" |
| Run an issue against `main`, then re-run it against a feature branch | preflight refuses, naming the branch recorded in the `Loop-Base-Branch:` trailer |
| Hit `LOOP_MAX_RUNS_PER_DAY` | red run **and** a comment on the issue saying the cap was hit and when it resets |
| **Cancel a run mid-Claude-step from the Actions UI** | blocked comment posted, card in **Blocked**, artifact present, **and the work pushed to `loop/issue-N`** |

That last one is the important one. It is case 6 in the escalation design — the run that
dies with nobody left to report it — and it has two separate `if:` conditions holding it up.
`escalate.sh` must stay on `if: always()`; `preserve-work.sh` must stay on
`if: failure() || cancelled()`. A cancelled job is **not** a failed one, so `failure()`
alone silently skips the step that saves your code, which is exactly what this test caught.

## Will my issue be accepted?

`preflight.sh` refuses an issue whose Acceptance criteria section it cannot parse, and the
refusal arrives at the top of a red run. Check first instead:

```bash
avengers-12/lib/check-issue.sh --issue 36
pbpaste | avengers-12/lib/check-issue.sh
```

Two rules, and both are easy to miss:

- The heading must contain the words **acceptance criteria**, in that order. `AC` and
  `Acceptance-criteria` do not match.
- Every criterion needs a **list marker** — `- `, `- [ ] `, `* `, `1. `. A paragraph is not
  a criterion. The verifier judges "does the diff satisfy item 3?", so there has to be an
  item 3.

## Bootstrap a queue

Most projects already have a to-do list or a fix list full of unchecked `- [ ]` items.
List those files under `seed.sources` in `avengers-12/config.yml`, then:

```bash
avengers-12/lib/seed-board.sh                        # dry run first
avengers-12/lib/seed-board.sh --create --add-to-board
```

Everything is created as `loop:needs-spec`, never `loop:ready` — a checklist line is a
title, not a specification.
