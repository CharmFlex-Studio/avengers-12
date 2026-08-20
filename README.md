# avengers-12

Write a GitHub issue. Get a draft pull request back.

You write an issue and label it. A GitHub Action reads it, writes the code, runs your
tests, and opens a draft PR. If the issue is unclear it stops and asks you on the issue.
You answer, and it keeps going. It never merges anything.

```
   you                          avengers-12                       you
    │                                │                             │
  write an issue ──────────────▶  reads it                         │
  label it loop:ready              writes the code                 │
    │                              runs your tests                 │
    │                              opens a draft PR ─────────────▶ review & merge
    │                                │
    │◀───── asks a question ─────  stuck?
  reply on the issue ────────────▶ carries on
```

## Will this work for me?

You need:

* A GitHub repo
* A Claude Pro or Max subscription. Runs are billed to it.
* Node 18 or newer, just to install
* Around 20 minutes

Any language works. Gradle, Node, Go, Python, Rust. You tell it how to build and test your
project in one config file.

**One catch about the board.** If you want cards moving on a GitHub Project board, your
repo and your board both have to sit inside an organisation. GitHub only offers the
"Projects" token permission for organisations. On a personal repo, cards never move.

Making an org is free and takes a minute: <https://github.com/account/organizations/new>.

Don't want to bother? Skip the board. The loop works fine on labels alone, and that's the
default setting.

## Install

### 1. Copy the files in

```bash
npx avengers-12 init
```

Anything you've already edited stays as it is.

### 2. Fill in the config

Open Claude Code in the same folder and run:

```
/setup-workflow
```

It looks at your project, writes `avengers-12/config.yml` for you, and tells you what's
left.

Not using Claude Code? Open `avengers-12/config.yml` and fill it in yourself. Every line
has a comment telling you what goes there. Then run `npx avengers-12 doctor` and fix
whatever it lists.

### 3. Install the Claude GitHub App

Go to <https://github.com/apps/claude> and install it on your repo.

### 4. Add the secrets

Go to **Settings → Secrets and variables → Actions**, then the **Secrets** tab.

| Secret | Required? | What to put in it |
|---|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | **Yes** | Run `claude setup-token` in a terminal and paste what it prints |
| `LOOP_PROJECT_TOKEN` | **Yes** | A GitHub token. See below |
| `LOOP_WEBHOOK_URL` | No | Any URL that takes a JSON POST. You get a ping when a run needs you |

To make the GitHub token, go to **Settings → Developer settings → Personal access tokens →
Fine-grained tokens** and click **Generate new token**. Set it up like this:

* Repository access: only this repo
* Repository permissions: **Contents**, **Issues** and **Pull requests**, all set to Read
  and write
* Want a board? Also set **Organisation permissions → Projects** to Read and write

If your repo belongs to an org, set *Resource owner* to the org rather than your username.
Someone with owner access then has to approve the token. Watch out for this one. An
unapproved token looks like it works and quietly does nothing.

### 5. Add the variables

Same page, but the **Variables** tab this time. It's easy to miss.

| Variable | Required? | What to put in it |
|---|---|---|
| `LOOP_PROJECT_NUMBER` | Only if you want a board | The number in your board's URL |
| `LOOP_PROJECT_OWNER` | Only if you want a board | The owner in your board's URL |
| `LOOP_PAUSE_ALL` | No | `false`. Switch it to `true` to stop everything at once |
| `LOOP_MAX_RUNS_PER_DAY` | No | Overrides the config file. Leave it out and the config wins |
| `LOOP_BOARD_OPTIONAL` | No | Overrides the config file. Leave it out and the config wins |

If you want a board and forget the first two, your labels will move but your cards won't.
Nothing goes red, so it's worth double checking.

### 6. Merge it to your main branch

Commit what got created and merge it. Replying to the loop's questions won't work until
this is on your default branch.

### 7. Check your work

```bash
npx avengers-12 doctor
```

It lists anything that's wrong. Fix, run again, repeat until it's quiet.

For a longer walkthrough of steps 3 to 6, see [`docs/setup.md`](docs/setup.md).

## Your first run

Write an issue. Say what you want, and how you'd know it worked:

```markdown
## Acceptance criteria
- [ ] An empty search box shows "Type to search" instead of a blank list
- [ ] A test covers the empty-input case
```

This bit matters. Those criteria are all the instructions the coder gets, so a vague issue
gets you vague code.

You can check the format before you spend a run:

```bash
avengers-12/lib/check-issue.sh --issue 36
```

Now label the issue `loop:ready`, then go to **Actions → Loop → Run workflow**.

Choose `triage-only` for your first go. It reads your issues and tells you what it makes of
them without writing any code. Have a look at that, then run it again with `mode: full`.
Around 20 minutes later you'll have a draft PR.

## Everyday use

| You want to | Do this |
|---|---|
| Add work to the queue | Write an issue and label it `loop:ready` |
| Start a run | Actions → Loop → Run workflow |
| Answer a question | Reply on the issue. It picks up again on its own |
| Stop everything | Set `LOOP_PAUSE_ALL` to `true` |

`loop:ready` is the only label you set. The rest belong to the loop.

When it asks you something, just reply normally. One thing to avoid: don't put `@claude` in
your reply. That goes to a different workflow and your answer gets lost.

## If something goes wrong

| What you see | What's happening |
|---|---|
| Red run right at the start | Setup isn't finished. Run `npx avengers-12 doctor` |
| `Invalid username or token` | Your token isn't approved, or a permission is missing |
| Cards aren't moving | Check the top of the run summary. It tells you why |
| Issue got `loop:needs-spec` | Too vague. Run `check-issue.sh` on it to see what's missing |
| Green run but nothing happened | Read the summary. It says what it decided and why |
| Replying does nothing | Your workflow isn't on the default branch yet. See step 6 |

Look at the run summary page first. The logs are a last resort.

## Settings

Everything lives in `avengers-12/config.yml`, and every setting has a comment explaining
it. The one to get right is how your project builds and tests:

```yaml
verify:
  - name: test
    run: npm test        # your real command here
```

## Commands

```bash
npx avengers-12 init      # copy the files in. Safe to run again
npx avengers-12 doctor    # check your setup
avengers-12/lib/check-issue.sh --issue 36
```

`init --force` gets you the latest scripts and workflows. Your config and your history stay
where they are.

## Status

Version 0.4.5. Still early.

It's used every day on one Gradle project, and tested against a Node project on every
change. Your runner needs `bash`, `jq` and `python3`, which `ubuntu-latest` already has.
Nobody has tried it on Windows.

MIT licensed.
[Setup guide](docs/setup.md) ·
[Rules](rules/constraints.md) ·
[Costs](rules/budget.md) ·
[Changelog](CHANGELOG.md) ·
[GitHub](https://github.com/CharmFlex-Studio/avengers-12)
