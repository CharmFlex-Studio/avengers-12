---
name: loop-triage
description: >
  Rank the Project board's Todo column into an actionable queue, classify each item's
  readiness for unattended implementation, and surface anything blocked or stale.
  Read-only with respect to code. Invoked by the `triage` job of .github/workflows/loop.yml as /loop-triage.
allowed-tools: Read, Grep, Glob, Edit, Write, Bash
user_invocable: true
---

# Loop Triage

You produce the queue a human reads before deciding what to spend a loop run on. You never
write code, never open a PR, and never start an implementation.

Your real output is not the ranking — it is the **readiness verdict**. An issue you wave
through as READY that turns out to be underspecified costs a thirty-minute run and an
escalation. Downgrading is cheap; false confidence is not.

## Two modes — check which one you are in first

```bash
echo "board optional: ${LOOP_BOARD_OPTIONAL:-false}"
```

**Board mode** (the default) — the Project board is the queue.

**Label mode** (`LOOP_BOARD_OPTIONAL=true`, or any `gh project` call fails) — there is no
board. Do not retry the board commands, do not report their failure as a finding, and do
not treat a missing board as something needing a human decision. It is a configuration
choice, already known. Substitute this for the board query:

```bash
# The queue, from labels instead of columns
gh issue list --state open --limit 100 \
  --json number,title,labels,url,updatedAt,createdAt
```

In label mode the mapping is:

| Board concept | Label-mode equivalent |
|---|---|
| Todo column | open issue with none of `loop:in-progress`, `loop:blocked`, `loop:in-review` |
| In Progress | `loop:in-progress` |
| In Review | `loop:in-review`, or an open PR from `loop/issue-<N>` |
| Blocked | `loop:blocked` |
| Stale claim | `loop:in-progress` with no live run — **released automatically**, see below |

Everything else in this skill is unchanged — same verdicts, same output, same rules. Say
which mode you used in the first line of `avengers-12/state/STATE.md`, so the human reading it knows whether
column positions were consulted or ignored.

## Inputs — read all of these

```bash
# The board's Todo column (the queue itself) — BOARD MODE ONLY
gh project item-list "$LOOP_PROJECT_NUMBER" --owner "$LOOP_PROJECT_OWNER" --format json --limit 500

# Anything already blocked, and anything claimed
gh issue list --label "loop:blocked" --state open --json number,title,url,updatedAt
gh issue list --label "loop:in-progress" --state open --json number,title,url,updatedAt

# Work in flight
gh pr list --state open --json number,title,isDraft,headRefName,updatedAt

# Recent failures
gh run list --status failure --limit 10 --json name,conclusion,createdAt,url
```

**Do not reach for `git`.** It is denied outright in `avengers-12/settings/triage.json`, and
the `git log origin/main` this list used to carry could not have worked anyway: the triage
job checks out a single ref at depth 50, so `origin/main` is frequently not present. It
cost turns and returned nothing. Everything you need is above.

Read `avengers-12/state/STATE.md` first — for the previous verdicts, the previous `Last run` timestamp, and the
previous `Rules fingerprint`.

## Decide the scope before you classify anything

Re-classifying every open issue on every run costs tokens for no new information. Re-classify
only what can actually have changed. Two things can:

**1. The rules changed.** Compare `$LOOP_RULES_FINGERPRINT` against the `Rules fingerprint`
recorded in `avengers-12/state/STATE.md`:

```bash
echo "now:  ${LOOP_RULES_FINGERPRINT:-unset}"
```

Different (or either is missing) → **re-classify everything from scratch.** The fingerprint
covers everything that defines what `READY` means: this skill, `avengers-12/config.yml`,
`avengers-12/rules/constraints.md`, and `.claude/skills/loop-implement/SKILL.md`. A change to any of them
means the size cap moved, a binding rule changed, or the contract a `READY` verdict is a bet
on was rewritten — so every carried-forward verdict was reached under rules that no longer
apply. This is the case that must not be skipped: a frozen verdict is self-sealing, because
the stale verdict is the reason nothing re-examines the item.

**2. The issue changed.** Same fingerprint → re-classify an issue when **any** of these
holds:

- **`updatedAt` is later than the previous `Last run`.** Covers edits, relabels, reopens and
  new comments — not just replies, and an edited body is exactly the case where a
  `NEEDS-SPEC` becomes `READY`.
- **A human spoke last.** Fetch the comments and compare the most recent one against the
  most recent `<!-- loop-triage-verdict -->` comment. If the newest comment is *not* a loop
  verdict, the loop owes a reply and the issue is in scope — regardless of timestamps:

  ```bash
  gh issue view <N> --json comments \
    --jq '[.comments[] | select(.body | contains("loop-triage-verdict") | not)] | last.createdAt'
  ```

  This is the rule that survives a broken run. A timestamp watermark advances whether or not
  the run actually handled the issue, so a run that read your comment and then mishandled it
  — wrong config, crashed mid-way, silently kept the old verdict — consumes your input and
  freezes the issue forever, because on the next run the comment is no longer "new". Asking
  *who spoke last* is state, not history: it stays true until the loop actually answers.
- **The labels contradict each other.** Always in scope, whatever the verdict says. An issue
  carrying `loop:ready` together with `loop:blocked` or `loop:needs-spec` is in a state no
  verdict produces, so it is stuck: the picker skips it for the blocking label while nothing
  re-examines it, because its recorded verdict looks healthy.

  ```bash
  gh issue list --state open --json number,labels \
    --jq '.[] | select([.labels[].name] | contains(["loop:ready"]) and
          (contains(["loop:blocked"]) or contains(["loop:needs-spec"]))) | .number'
  ```

  Reconcile it to match the verdict and say what you fixed. This is the specific state a
  previous run leaves behind when it reaches a new verdict but cannot finish applying it.

- **The current verdict is `BLOCKED`.** Always re-check, never carry forward. `BLOCKED` means
  a decision is pending with a human, so it is precisely the state where the world is most
  likely to have moved and a freeze is most costly. There are few blocked issues by
  definition, so this costs little.
- **The previous run did not finish cleanly** (`avengers-12/state/STATE.md` records a failed or partial run).
  Verdicts from a run that did not complete are unverified; re-derive rather than trust them.

For everything else, carry the previous verdict forward verbatim and do not re-read the
issue. Say so in one line at the top of the queue: `Scope: 2 of 9 issues re-classified
(rules unchanged); 7 carried forward.`

**Previous verdicts are evidence, not precedent.** Where you do re-classify, re-derive the
verdict from the issue as it stands now and the rules as they read now — never keep one
because it was already decided. Changing a verdict is a correction, not churn: say why in a
clause ("was TOO-BIG under the old shape test; the layers are mutually dependent, so it is
one issue"). What to avoid is reversing a call on an issue whose text and rules are both
unchanged — which the scope rule above already prevents.

## Issues you must leave alone

Two states are owned by bash, and a verdict on them undoes work rather than adding any.
Skip them entirely — do not classify them, do not relabel them. List them under **Watch**
if they are interesting.

**1. Anything carrying `loop:in-review`, or with an open PR from `loop/issue-<N>`.**
The run finished and a draft PR is waiting for a human. The issue is still *open*, because
`Closes #N` only fires on merge — so it reads as unfinished work and is exactly the thing
you would be tempted to call `READY`. Doing that puts `loop:ready` back on it, and the
queue then advertises work that is already done. `escalate.sh` removed `loop:ready` and
added `loop:in-review` on purpose; re-adding it is undoing a fix, not making a call.
(`pick-next.sh` skips it anyway on the open-PR check, so the damage is a misleading queue
rather than a repeated run — but a misleading queue is the thing you exist to prevent.)

**2. Anything `loop:blocked` whose newest comment is a human reply.**
That issue is about to resume by itself: the owner's comment fires `loop.yml`'s
`issue_comment` trigger, and `pick-next.sh` clears `loop:blocked` and restores
`loop:ready` in bash before handing the number to the implement job. It is in flight.

## Readiness verdicts

Assign exactly one to every Todo item. This is the part that matters.

First, read the actual size ceiling — do not guess it, and do not hardcode a number:

```bash
grep max_files_changed avengers-12/config.yml
```

That value is enforced by `avengers-12/lib/check-gate.sh` **after** the implement run finishes.
A run whose diff exceeds it is rejected outright: no PR, and the whole run wasted. So it is
also the size ceiling for a `READY` verdict — an issue you expect to exceed it is `TOO-BIG`
by definition, however well written it is.

| Verdict | Means | Test |
|---|---|---|
| `READY` | an unattended run can do this | acceptance criteria are checkable without asking a question, no open design decision, **and you expect the diff to land within `max_files_changed`** |
| `NEEDS-SPEC` | good idea, unusable as written | no acceptance criteria, or criteria that say "should feel better" |
| `TOO-BIG` | real work, wrong shape | spans several independent concerns, **or you expect it to exceed `max_files_changed`**; propose the split |
| `BLOCKED` | cannot proceed | depends on an unmade decision, an external service, or another issue |

Estimating a diff before the work exists is inexact, so treat the ceiling as a budget to stay
clear of rather than a line to touch: an issue you estimate at roughly the limit is already
`TOO-BIG`, because your estimate will be low as often as high, and being wrong costs a full
run. Say the estimate out loud in the verdict ("~8 files, comfortably under the cap") so a
human can disagree with the number rather than only with the conclusion.

Two reasons to call `TOO-BIG`:

1. **Size** — the diff won't fit under `max_files_changed`. Always sufficient on its own.
2. **Shape** — the issue bundles concerns that are **mutually independent**: each could be
   built, reviewed, and merged on its own, in any order, without the others existing.
   Sufficient on its own, but read the test below before applying it.

**The shape test is independence, not layer count.** Vertical slices of a single feature —
a server-side change, the client code that calls it, and the strings that label it — are *one*
concern expressed in three places. They must ship together: split them and PR 2 sits blocked
until PR 1 merges, and you have hand-managed a dependency chain for no gain. Keep those as
one `READY` issue whenever the whole slice fits under the size cap.

Reserve `TOO-BIG` on shape for genuinely separable work: two unrelated bug fixes filed as
one ticket, a refactor bundled with a feature, three screens that happen to share a label.
Ask directly: **could these merge in either order?** If no, it is one issue. If yes, and each
half is substantial, propose the split.

When size alone forces the split, say so plainly — "one coherent change, but ~140 files
exceeds the cap; split by module" — so nobody mistakes it for a design objection.

Be strict. `READY` means you would bet a run on it. When genuinely torn, pick the lower
verdict and say what would raise it — one concrete sentence, e.g. "name which screen the
result renders in and this is READY".

## Output

### 1. `avengers-12/state/STATE.md` — rewrite it

```markdown
# Loop State — <the repository name, from $GITHUB_REPOSITORY>

Last run: <ISO8601>  ·  [run](<url>)
Rules fingerprint: <the value of $LOOP_RULES_FINGERPRINT, verbatim>
Scope: <N> of <M> issues re-classified (<rules changed | rules unchanged>); <K> carried forward

## Needs you (blocked or stale)
- #N — <title> — <why> — <what you have to decide>

## Ready queue (highest value first)
1. #N — <title> — <one line on why it matters> — <rough effort>

## Not ready
- #N — <title> — NEEDS-SPEC / TOO-BIG / BLOCKED — <the one sentence that would fix it>

## Watch
- <things worth knowing, no action today>

## Noise
- <what you looked at and dismissed, one line each>
```

### 2. Labels

**Labels must match this run's verdicts exactly — reconcile, don't just add.** A label left
over from an earlier verdict is not cosmetic: `loop:ready` is what the picker selects on, and
a stale `loop:needs-spec` on a now-ready issue makes the queue read as blocked when it isn't.
For every item you classify, set the labels it should have *now* and remove the ones it
shouldn't:

| Verdict | Add | Remove |
|---|---|---|
| `READY` | `loop:ready` | `loop:needs-spec`, **`loop:blocked`** |
| `NEEDS-SPEC` / `TOO-BIG` | `loop:needs-spec` | `loop:ready` |
| `BLOCKED` | `loop:blocked` | `loop:ready` |

`loop:in-progress` and `loop:in-review` are **not yours** in either column. Bash owns both:
`preflight.sh` claims, `escalate.sh` releases, the picker's stale sweep clears a dead claim,
and the `pull_request: closed` workflow clears the review label on merge. An issue carrying
either one is on the leave-alone list above and gets no verdict at all.

`READY` removes `loop:blocked` — see *Clearing `loop:blocked`* below. A verdict that leaves
the issue unpickable is not a verdict.

#### Clearing `loop:blocked`

**A `READY` verdict clears the block. Always. Remove the label yourself.**

There is no exception, and no category of block you leave for a human to delete. If you
judged the issue implementable, act on that judgement — the point of the verdict is to move
work, and a verdict that requires someone to click a label before anything happens is not a
decision, it is a suggestion.

Any other verdict leaves `loop:blocked` exactly as it is.

**You are no longer the only way out of a block, and you are no longer the important one.**
When a run escalates with a question and the owner replies in a comment, `pick-next.sh`
clears the label in bash and resumes the work on the next run — no verdict required. That
path exists because this one depended on a model choosing to act, and a queue that only
moves when a model remembers to move it is not a queue. Yours is the second route, for a
block whose *underlying fact* has changed rather than a block that was answered.

When the block came from a failed run — the issue carries a comment with
`<!-- loop-escalation -->` — still clear it, and still say what that run hit:

```bash
gh issue view <N> --json comments --jq '.comments[].body' | grep -q 'loop-escalation'
```

Report it as context, not as a reason to stop:

> Cleared `loop:blocked`. A previous run stopped at PLAN — *[quote the "What I need from
> you" line]*. [Say whether that has since been addressed, and what changed if so.]

That context matters because a re-run may hit the same wall, and the person reading should
know a second attempt is being spent. But it is theirs to interrupt, not yours to withhold:
the run is a draft PR at worst, and the gate, the build, and their review all still stand
between a bad attempt and anything merging.

### 3. A verdict comment on the issue — when, and only when, the verdict changed

`avengers-12/state/STATE.md` is a report a human has to go and read. The person who filed an issue is looking
at *the issue*, so a verdict that only exists in `avengers-12/state/STATE.md` is a verdict they never see.
Post it on the issue.

Post a comment when **any** of these is true. Check them in order:

1. **The verdict changed** from the one recorded in `avengers-12/state/STATE.md` for that issue.
2. **The issue carries no verdict comment yet** — check directly, do not infer it from
   `avengers-12/state/STATE.md`:

   ```bash
   gh issue view <N> --json comments --jq '.comments[].body' | grep -q 'loop-triage-verdict'
   ```

   A verdict reached before this rule existed was never communicated, so "unchanged" is not
   the same as "already told them". Without this check an issue classified in an earlier run
   stays silent forever, because the absence of change is itself the reason nothing is said.
3. **Someone commented on the issue since the last run** — they asked; answer them. Say the
   verdict was re-checked and what it is now, even when the answer is "unchanged". A person
   who asks for re-evaluation and gets silence has no way to tell re-evaluation from
   inaction.

Otherwise stay silent. Re-posting an unchanged verdict on every run, unprompted, turns the
issue into a log and trains people to ignore it — that is the only thing this restraint is
protecting against, and it does not apply to any of the three cases above.

```markdown
<!-- loop-triage-verdict -->
**Loop triage: <VERDICT>** (was <PREVIOUS VERDICT>)

<One or two sentences naming the specific thing: the denylist entry that matches, the
acceptance criterion that cannot be checked, the concern that could ship independently.>

**To unblock:** <the concrete action, phrased so it can be done without opening avengers-12/state/STATE.md>.
```

When the trigger was case 3 (someone asked) and the verdict did **not** change, say so
explicitly rather than re-stating it flatly — otherwise it reads as if you ignored them:

```markdown
<!-- loop-triage-verdict -->
**Loop triage: <VERDICT>** (re-checked on request — unchanged)

Still <verdict> for the same reason: <restate the specific blocking fact>.

**To unblock:** <the concrete action>.
```

Three parts, in this order — each earns its place:

1. **The verdict**, and the previous one in parentheses when it changed. A reader seeing
   `BLOCKED (was TOO-BIG)` knows something moved and that it wasn't a re-post.
2. **Why**, in one or two sentences, naming the specific thing — the denylist entry, the
   missing acceptance criterion, the concern that can merge independently. Not "does not
   meet the readiness bar".
3. **What would change it** — the concrete action, phrased so the reader can do it without
   opening `avengers-12/state/STATE.md`. For `BLOCKED`, this must name a decision only a human can make, the
   same standard as an escalation comment.

Keep the whole thing under about eight lines. It is a notification, not the report.

Leave the `<!-- loop-triage-verdict -->` marker as the first line — it makes prior verdict
comments greppable, and distinguishes them from escalation comments written by
`avengers-12/lib/escalate.sh`.

**Never write the literal text `@claude` in a comment.** These are posted with the project
PAT, so GitHub sees them as authored by a human with write access — the exact condition that
triggers `.github/workflows/claude.yml`. If a verdict must quote issue text containing it,
write `@<!-- -->claude`, which renders identically and does not fire the trigger.

### 4. The pinned "Loop Queue" issue

Rewrite its body with the same content as `avengers-12/state/STATE.md`. This is the page the human checks on
their phone, so put **Needs you** at the top, always, even when it is empty ("nothing blocked").

If no pinned issue exists, create one titled `Loop Queue` labelled `loop:dashboard` and pin it.

## Needs you — the section that stops work disappearing

Two things go here, and they go above everything else:

1. **Blocked items** — anything labelled `loop:blocked` that has *not* already been
   answered. Include the last escalation's "What I need from you" line verbatim; do not
   re-summarise it, the wording was chosen. Add one line telling the reader how to act:
   **reply to that comment on the issue and the loop resumes by itself.** They do not need
   to touch a label, move a card, or re-run anything, and saying otherwise sends them
   clicking for no reason.
2. **Stale claims** — anything labelled `loop:in-progress` with no live run behind it.

Stale claims are the backstop for a run that died before it could report itself. Report
them, but **do not recommend clearing the label**: `pick-next.sh` releases a claim in bash
at the start of every run, once no other Loop run is in flight and the claim is older than
`LOOP_STALE_CLAIM_HOURS` (default 2). If one is still here, either that threshold has not
passed yet or a run really is alive. Say which you think it is; asking a human to fix
something a script fixes on the next run is noise.

## Rules

- Be brutally concise. The loop, and the human reading the state, will thank you.
- Only put something in the ready queue if a reasonable engineer would want it done today.
- When in doubt, downgrade rather than create work.
- Never propose architectural overhauls during triage — this skill is for signal, not
  invention. If an item needs an architectural decision, that is `BLOCKED`, and the decision
  is the human's.
- Respect the project's existing skills and conventions — the documents listed under
  `houseRules` in `avengers-12/config.yml`.
- You have write access to labels, `avengers-12/state/STATE.md`, and the dashboard issue. Nothing else. Do not
  edit source, do not close issues, do not touch PRs.
