# Changelog

## 0.6.1 — 2026-08-20 *(not published)*

- **A fresh install failed `doctor`.** The starter config listed `AGENTS.md` and
  `CLAUDE.md` under `houseRules`, and most projects have neither. It now ships
  empty, and empty is a valid answer rather than a fault.
- `houseRules` is explained in the README and in plain words in the config,
  instead of only being named. It is the list of documents the coder reads before
  it writes anything.
- The install test created `AGENTS.md` and `CLAUDE.md` before checking, which is
  exactly why it never caught this. It no longer does.

## 0.6.0 — 2026-08-20 *(not published)*

- **The timer is on by default, at once a day.** It used to ship off. Set
  `schedule.everyHours` to change it, or 0 to turn it off.
- **The minimum is now 1 hour.** GitHub is asked every hour instead of every four,
  so `everyHours: 1` means what it says.
- A scheduled run stops before doing anything if `CLAUDE_CODE_OAUTH_TOKEN` is not
  set, so a repo somebody installed and never finished setting up does not
  produce a red run every day for ever.
- The hourly check only fetches the `avengers-12/` folder, not your whole repo.
- A non-numeric `everyHours` turns the timer off rather than running every hour.
  A typo should stop it, not start it.

## 0.5.0 — 2026-08-20 *(not published)*

- **The loop can run on a timer.** Set `schedule.everyHours` in the config and it
  starts itself. 0 is off, and off is the default. GitHub checks every four
  hours and skips if it is too soon, so anything under 4 behaves like 4.
- **No limit on runs you start yourself.** `maxRunsPerDay` used to refuse a third
  manual run, which was friction with nothing behind it: you were sitting there,
  you knew you were spending a run. It now applies to scheduled runs only, where
  it is the brake for something going wrong while you sleep.

## 0.4.7 — 2026-08-20 *(not published)*

- The daily cap now counts a `failed` outcome. It was the one outcome the counter
  did not know about, so if that path ever fired, runs would stop counting and
  the cap would quietly stop capping.
- `rules/budget.md` lists which outcomes count and which do not. Short version:
  once a run claims an issue it counts, however it ends. Refusals before that are
  free.

## 0.4.6 — 2026-08-20 *(not published)*

- Said plainly that nothing runs on a timer. `maxRunsPerDay` is a ceiling, not a
  schedule: it stops a third run today, it never starts one. The name reads like
  a plan, and an old README line made it worse by claiming the loop ran twice a
  day.

Versions marked *not published* exist as git tags only. If you installed from npm you
skipped straight from the version before to the one after.

## 0.4.5 — 2026-08-20 *(not published)*

- README rewritten for somebody installing it. It says what to do and stops there, instead
  of also explaining how the loop works inside.

## 0.4.4 — 2026-08-20 *(not published)*

- Put the flow diagram back. Cutting it in 0.4.3 was a mistake.

## 0.4.3 — 2026-08-20 *(not published)*

- README cut roughly in half. The full detail is still in `docs/setup.md` and `rules/`.

## 0.4.2 — 2026-08-20 *(not published)*

- Setup is seven numbered steps, one action each.
- Secrets and variables are tables with a **Required?** column, so you can see at a glance
  what you actually need.

## 0.4.1 — 2026-08-20

- **The README never told you to set the repository variables.** Follow it exactly and your
  board would never work. Now step 5.
- **`LOOP_WEBHOOK_URL` did nothing.** The script read it, but no workflow ever passed it
  through. Setting the secret sent no notifications.
- `setup-status.sh` reports which required secrets and variables are *missing*, rather than
  listing the ones you already have.

## 0.4.0 — 2026-08-20 *(not published)*

- **If your reply doesn't restart the loop, it now tells you on the issue.** It used to say
  so only on the run summary, so you would reply, watch the issue, and see nothing.
- **An organisation is now listed as a requirement for the board.** GitHub only offers the
  Projects token permission to organisations, so on a personal repo cards never move and
  nothing says why. Running on labels alone still works anywhere.
- `doctor` catches bash 4 syntax. macOS ships bash 3.2, so scripts that worked on the
  runner could break on your laptop.

## 0.3.0 — 2026-08-20

No code changes. Same as 0.2.2, released under a new number.

## 0.2.2 — 2026-08-19

The board and the reply flow, after two full reviews of the harness.

**Fixed**

- `.loop/` was not ignored by git on a fresh install, so every draft PR carried about
  eighteen of the loop's own scratch files. It also meant a run where nothing was written
  still looked like it had changed something.
- Replying to a blocked issue never worked if triage was what blocked it.
- Replying with GitHub's **Quote reply** button never worked at all, on any issue.
- A board with a renamed label silently stopped accepting replies.
- The advisory reviewer was hardcoded to Kotlin. It's `review.agent` in the config now.
- `sync-board.sh` stopped after the first issue, and reported "moved 4 of 5" when it had
  moved none.
- Four claims in the docs that the code did not actually do.

**Added**

- `check-issue.sh` tells you whether an issue will be accepted before you spend a run on
  it.
- `check-board.sh` checks the board can actually be written to, not just read. A read-only
  token used to pass every check and then refuse every card move.
- Board and comment failures print what GitHub actually said, instead of a guess.

## 0.2.1 — 2026-08-19

The board tells the truth.

- Cards reached In Review but never In Progress.
- Renaming a column in the config had no effect on where cards went.
- Cards now follow the labels on every run, including labels you set by hand.
- `doctor` checks the board resolves and has every column your config names.
- A board that can't move a card says so on the run summary instead of staying quiet.

## 0.2.0 — 2026-08-19

- `/setup-workflow`. Run it after `init` and it fills in your config, creates the labels,
  and lists the browser steps it can't do for you.

## 0.1.0 — 2026-08-19

First release.

- `npx avengers-12 init` copies the harness into a repo, `doctor` checks it.
- Everything project-specific lives in one `config.yml`.
- Tested against a Node project, which is not the kind of project it was written in.
