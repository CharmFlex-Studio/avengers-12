---
name: loop-constraints
description: >
  Reference for the binding rules in avengers-12/rules/constraints.md and which of them a script
  actually enforces. NOT auto-invoked — the loop-implement orchestrator reads
  avengers-12/rules/constraints.md and avengers-12/config.yml itself during PLAN. Invoke by hand with
  /loop-constraints when you want the rules in front of you.
user_invocable: true
---

# Loop Constraints

**Nothing runs this skill automatically.** It used to say it ran "BEFORE triage or any
action skill", and that was simply untrue: the only prompts the workflow issues are
`/loop-triage` and `/loop-implement <N>`, and a skill nobody invokes enforces nothing.
Believing otherwise is worse than not having it — it makes a rule look guarded when it is
not.

What actually happens: step 3 of the `loop-implement` orchestrator's PLAN state reads
`avengers-12/rules/constraints.md` and `avengers-12/config.yml` and digests them into the implementer's brief. That
is the real load path. This file is the reference behind it, and a thing you can invoke by
hand.

If you are reading this because you invoked it:

1. Read `avengers-12/rules/constraints.md` from the project root.
2. Read `avengers-12/config.yml` — the denylist that will be enforced against your diff.
3. Load both into working memory and apply them to every action that follows.

Then say, in one line:

```
Constraints loaded: N rules from avengers-12/rules/constraints.md, M denylist patterns from avengers-12/config.yml.
```

## Know which rules can stop you

Some constraints are enforced by machinery and some are only enforced by you. Treating the
second kind as optional is how a loop drifts, so know the difference:

**Machine-enforced** — you cannot violate these, only waste a run trying:

| Rule | Enforced by |
|---|---|
| Path denylist | `avengers-12/lib/check-gate.sh` after you finish; also `avengers-12/settings/implement.json` deny rules while you work, which now mirror `avengers-12/config.yml` entry for entry so a denied write is refused at the moment you attempt it rather than an hour later at the gate |
| No push, no PR creation, no merge | harness deny rules; a workflow step does the pushing |
| Max files per change | `check-gate.sh` (`max_files_changed` in `avengers-12/config.yml`) |
| Tests must pass | `avengers-12/lib/verify.sh`, run independently of anything you report |
| Max 3 fix attempts | `.loop/attempts.json`, written by `evidence.sh` |
| Daily run cap, kill switch | `avengers-12/lib/preflight.sh` and the job-level `if:` |

**Advisory — genuinely yours to honour:**

- One fix per run; no refactoring unrelated code.
- Tell the human what you are about to do before doing it.
- Never close an issue or PR without approval.
- Never disable a test to make CI green. (The verifier looks for this specifically, but
  nothing mechanically stops you writing it, so don't.)
- Escalate rather than guess when acceptance criteria are ambiguous.

## How to enforce

- **Before editing a file**: check it against `avengers-12/config.yml`. A denied path fails the whole run
  at the gate, wasting everything you did before it — check first, not after.
- **Before proposing a fix**: run the tests. One fix per run.
- **Before finishing**: re-read the Push & Merge section. You commit; you never push.
- **If `loop-pause-all` is active**: exit immediately.

## Interaction with the rest of the harness

- `loop-triage` — constraints may override triage priority.
- `loop-implement` — **this is the only automatic reader.** PLAN step 3 opens
  `avengers-12/rules/constraints.md` and `avengers-12/config.yml` and digests them into `.loop/brief.md` for the
  implementer, which starts cold and sees nothing that is not in the brief.
- `loop-verifier` — rejects on `house-rules` when a constraint was ignored.
- `loop-budget` — reference only; enforcement is in bash and the run log is written by
  `avengers-12/lib/append-run-log.sh`.

## If `avengers-12/rules/constraints.md` is missing

Say so plainly, then enforce these minimums:

- Never edit `.env`, `.env.*`, `auth/`, `payments/`, `secrets/`, `credentials/`
- Never edit the harness's own files: `.github/`, `.claude/`, `avengers-12/lib/`, `avengers-12/config.yml`
- Never auto-merge to `main`
- Never disable tests
- Escalate after 3 failed attempts
