# avengers-12

Write a GitHub issue. Get back a draft pull request.

You describe what you want and add a label. A GitHub Action picks the issue up, writes the
code, runs your tests, and opens a draft PR. If it can't work out what you meant, it stops
and asks on the issue. You reply, and it carries on.

It never merges. You review every PR yourself.

## Before you start

- A GitHub repo. **For the board, the repo and board must belong to an organisation** —
  the token permission that moves cards only exists there. Orgs are free.
  You can also skip the board and run on labels alone, which is the default.
- A Claude Pro or Max subscription. Runs bill against it.
- Node 18+ to install. The harness itself is bash and python.
- About 20 minutes, mostly in GitHub settings.

Your project can be Gradle, Node, Go, Python, Rust, anything. You say how to build and test
it in one config file.

## Setup

### 1. Copy the files in

```bash
npx avengers-12 init
```

Won't overwrite anything you've already edited.

### 2. Fill in the config

In Claude Code, same folder:

```
/setup-workflow
```

It reads your project, writes `avengers-12/config.yml`, and lists what's left to do.

No Claude Code? Edit `avengers-12/config.yml` by hand — every line has a comment — then run
`npx avengers-12 doctor` until it's quiet.

### 3. Install the Claude GitHub App

<https://github.com/apps/claude>, on your repo.

### 4. Add the secrets

**Settings → Secrets and variables → Actions → Secrets tab**

| Secret | Required? | What it is |
|---|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | **Yes** | Run `claude setup-token` and paste the output |
| `LOOP_PROJECT_TOKEN` | **Yes** | A fine-grained PAT, see below |
| `LOOP_WEBHOOK_URL` | No | Any URL taking a JSON POST. Pings you when a run needs you |

For the PAT: **Settings → Developer settings → Personal access tokens → Fine-grained
tokens → Generate new token**

- Repository access: only this repo
- Repository permissions: **Contents**, **Issues**, **Pull requests** — Read and write
- Using a board? Also **Organisation permissions → Projects → Read and write**

Org-owned repo? Set *Resource owner* to the org, then get an owner to approve the token.
An unapproved token works perfectly and sees nothing.

### 5. Add the variables

**Same page, Variables tab.** Different tab from Secrets, easy to miss.

| Variable | Required? | Value |
|---|---|---|
| `LOOP_PROJECT_NUMBER` | Only with a board | The number in your board's URL |
| `LOOP_PROJECT_OWNER` | Only with a board | The owner in your board's URL |
| `LOOP_PAUSE_ALL` | No | `false`. Set `true` to stop every loop instantly |
| `LOOP_MAX_RUNS_PER_DAY` | No | Overrides the config. Unset means the config wins |
| `LOOP_BOARD_OPTIONAL` | No | Overrides the config. Unset means the config wins |

Want a board and skip the first two? Labels move, cards don't, and nothing turns red.

### 6. Merge to your default branch

GitHub only runs a workflow from the default branch when someone comments on an issue.
Until this is merged, replying to a question does nothing.

### 7. Check it

```bash
npx avengers-12 doctor
```

Fix what it names, run it again, repeat until quiet.

Longer version of steps 3–6: [`docs/setup.md`](docs/setup.md).

## Your first run

Write an issue saying what you want and how you'd know it worked:

```markdown
## Acceptance criteria
- [ ] An empty search box shows "Type to search" instead of a blank list
- [ ] A test covers the empty-input case
```

Those criteria are the whole spec the coder gets. Vague criteria give you vague code.

Check the format before spending a run:

```bash
avengers-12/lib/check-issue.sh --issue 36
```

Then add the label `loop:ready`, and go to **Actions → Loop → Run workflow**.

Pick `triage-only` the first time — it reads your queue and tells you what it thinks
without spending a run. Then run it again with `mode: full`. About 20 minutes later you get
a draft PR.

## Day to day

| To do this | Do this |
|---|---|
| Queue up work | Write an issue, label it `loop:ready` |
| Start a run | Actions → Loop → Run workflow |
| Answer a question | Reply on the issue. It restarts by itself |
| Stop everything | Set `LOOP_PAUSE_ALL` to `true` |

You only ever set `loop:ready`. The other labels — `loop:in-progress`, `loop:in-review`,
`loop:blocked`, `loop:needs-spec` — are the loop's.

When it asks you something, reply in plain words. Don't write `@claude`: that belongs to a
different workflow and your answer goes to the wrong place.

## When something goes wrong

| You see | It means |
|---|---|
| Red run at the first step | Setup isn't finished. Run `npx avengers-12 doctor` |
| `Invalid username or token` | The token isn't approved, or is missing a permission |
| Cards don't move | Read the top of the run summary. It says why |
| Issue got `loop:needs-spec` | Too vague. Run `check-issue.sh` on it |
| Green run, nothing happened | Read the summary. It says what it decided |
| Nothing happens when you reply | The workflow isn't on your default branch yet (step 6) |

Start at the run summary, not the logs.

## Configuration

Everything project-specific is in `avengers-12/config.yml`, and every key has a comment.
The one that matters most:

```yaml
verify:
  - name: test
    run: npm test        # your real command
```

If that doesn't actually run your tests, "tests passed" means nothing.

## Commands

```bash
npx avengers-12 init      # copy the harness in. Safe to run again
npx avengers-12 doctor    # 16 checks on your installation
avengers-12/lib/check-issue.sh --issue 36
```

`init --force` refreshes the scripts and workflows. It never touches `config.yml` or your
run history.

## Status

Version 0.4.3. Early. The logic is bash and python; npm is just how it reaches your repo.

Used daily on one Gradle project, tested on every commit against a scratch Node project.
Needs `bash`, `jq` and `python3` on the runner. Windows runners untested.

MIT. [Setup guide](docs/setup.md) · [Rules](rules/constraints.md) · [Costs](rules/budget.md)
· [Changelog](CHANGELOG.md) · <https://github.com/CharmFlex-Studio/avengers-12>
