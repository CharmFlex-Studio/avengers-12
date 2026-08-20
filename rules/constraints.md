# Loop Constraints

> The `loop-implement` orchestrator reads this file during PLAN and digests it into the
> implementer's brief. That is the only automatic reader — no skill runs "before every
> run"; the workflow issues exactly two prompts, `/loop-triage` and `/loop-implement <N>`.
> Constraints here are **binding**.
>
> Each rule below is marked with how it is enforced:
> **[machine]** — a workflow step blocks it; you cannot violate it, only waste a run trying.
> **[advisory]** — nothing mechanically stops you. Honour it anyway.
>
> A **[machine]** mark is a promise that a named script does the blocking. If you add a rule
> here, mark it [advisory] unless you can name the script.

## Push & Merge

- **[machine]** Never push. Claude commits locally; a workflow step decides what gets pushed
  after the gate and the build have passed. Enforced structurally rather than by rule:
  `actions/checkout` runs with `persist-credentials: false` and `GH_TOKEN` is never set on
  the Claude step, so no credential exists in the job for the agent to push with. The
  `Bash(git push:*)` deny in `avengers-12/settings/implement.json` is a second layer — on its own it
  is only a prefix match and `git -C . push` would slip past it.
- **[machine]** Never create or merge a pull request. The workflow opens a draft PR; a human
  marks it ready and merges.
- **[advisory]** Never commit to `main`. All work happens on `loop/issue-<N>`. Nothing
  mechanically prevents `git checkout main && git commit` — but with
  `persist-credentials: false` on checkout, such a commit can never leave the runner.
- **[advisory]** Say what you are about to do before doing it.

## Paths

- **[machine]** Never edit anything matched by `gate.deny` in `avengers-12/config.yml`.
  **Read the list from that file; it is not copied here.** The same argument applies to a
  path list as to a number: a denylist written in two places drifts, and the copy you read
  is then the wrong one. The categories it covers, so you know what to expect:
  - the harness's own files, because a run that can edit its own guardrails can widen its
    own permissions, which makes every other rule here decorative
  - the `houseRules` documents, because they are loaded on every later run, so an edit
    there is a durable change to how the loop behaves
  - secrets and signing material
  - the build wrapper
  - anything no `verify` step can check, because a green run that verified nothing is worse
    than a refused one
- **[machine]** Never change more than `gate.maxFilesChanged` files in one run. **Read the
  number from `avengers-12/config.yml`; it is not repeated here.** This exact line once
  promised 25 while the gate allowed 100 — a doc that lies about a machine-enforced rule is
  worse than no doc, because you plan against it.
  `avengers-12/lib/check-gate.sh` inspects the real diff after you exit.

The authoritative list is `avengers-12/config.yml`, checked by `avengers-12/lib/check-gate.sh` against
the actual diff after the agent has finished. It is also the only place the list is written:
`avengers-12/lib/emit-settings.sh` turns every `gate.deny` entry into a `Write()` and an
`Edit()` rule before each run, so a denied path is refused the moment you try to write it
rather than an hour later at the gate. **Do not copy the list into
`avengers-12/settings/implement.json`** — that file holds only the rules that are the same
for every project. Two copies of a denylist drift, and the drifted one is always the one
you are reading.

## Code

- **[machine]** Every `verify` step in `avengers-12/config.yml` must pass.
  `avengers-12/lib/verify.sh` runs them independently of anything the agent reports.
- **[advisory]** New behaviour gets a test, under `tests.directory` from
  `avengers-12/config.yml`. Note that the step above is green when a change adds no tests at
  all, so this one is genuinely yours; the verifier checks for it. Anything under
  `tests.notRun` does **not** run in the gate and is not evidence.
- **[advisory]** Never disable, skip, or `@Ignore` a test to make the build green. The
  verifier looks for this specifically, under reason code `cheating`.
- **[advisory]** Never refactor unrelated code — one fix per run. Real problems you notice
  along the way go in `.loop/changes.md` under "Discovered" and become their own issue.
- **[advisory]** Follow every document listed under `houseRules` in
  `avengers-12/config.yml`. They hold this project's standing rules and are the only place
  those rules are written down. The verifier rejects on them under `house-rules`.
- **[machine]** At most `budget.maxAttemptsPerRun` fix attempts **per run**, not per issue. `avengers-12/lib/evidence.sh`
  counts attempts in `.loop/attempts.json` and **refuses to produce a fourth evidence
  packet**, so the limit holds whether or not the orchestrator is paying attention.
  `preflight.sh` writes a fresh `attempts.json` at the start of every run, so a second run
  on the same issue starts again at 1. That is deliberate — a new run is a new agent with a
  new brief, and often a human answer that did not exist before — but it does mean the
  ceiling is three attempts per run, and this line used to claim otherwise.
- **[advisory]** Two rejections with the same reason codes escalate immediately rather than
  spending the third. This one is the orchestrator's judgement; bash only enforces the
  hard ceiling.

## Communication

- **[advisory]** Never close an issue or PR without approval.
- **[machine]** Every escalation posts a comment on the source issue naming the decision the
  human has to make. `avengers-12/lib/escalate.sh` runs on `if: always()`, so this survives a
  cancelled run or a dead runner.
- **[machine]** A reply to that comment resumes the work. `loop.yml`'s `issue_comment`
  trigger fires on a comment from the owner, a member or a collaborator on a `loop:blocked`
  issue, and `avengers-12/lib/pick-next.sh` clears `loop:blocked` and restores `loop:ready` in
  bash once a human comment is newer than the newest `<!-- loop-escalation -->`. Nobody
  clicks a label. So write escalation questions to be answerable in a comment.
- **[advisory]** "What I need from you" in an escalation must name a decision. If you cannot
  fill it in, file a separate `loop:discovered` issue instead.

## Budget

- **[machine]** Daily implement cap (`budget.maxRunsPerDay` in `avengers-12/config.yml`,
  overridable for a while with the `LOOP_MAX_RUNS_PER_DAY` repository variable), checked by
  `avengers-12/lib/preflight.sh` before Claude is invoked. On refusal it comments on the issue
  saying the cap was hit and when it resets, so a red run is never unexplained.
- **[machine]** One run at a time — `concurrency: group: loop` in `loop.yml`, covering
  triage and implement together.
- **[machine]** Turn cap (`--max-turns`) and wall clock (`timeout-minutes: 45`).
- **[machine]** Kill switch: repo variable `LOOP_PAUSE_ALL=true` stops `loop.yml` — triage and implement both. `loop-board-done.yml` is NOT paused by
  it: it only reacts to a pull request closing, and a card stranded in the wrong lane
  because the kill switch was on is a worse outcome than it doing its one job.
- **[machine]** Timer switch: repo variable `LOOP_PAUSE_SCHEDULE=true` stops scheduled
  firings only, in `schedule-gate.sh`. Dispatches and issue-comment resumes are untouched —
  you asked for those, so they are not the timer's business.

---
<!-- Add your own rules below. Use plain English. The loop reads this verbatim. -->
<!-- Mark new rules [machine] only if a script actually enforces them. -->
