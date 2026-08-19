# Changelog

## 0.2.0 — unreleased

Setup no longer starts at a blank config file.

- `/setup-workflow` skill. Run it after `init`: it reads what kind of project this
  is, writes `config.yml` from that, creates the labels, and hands back the setup
  steps that happen in a browser and cannot be automated.
- `lib/detect-project.sh` — reports the project's build files, test directories,
  nested builds and secret-shaped files as JSON. Facts only; it makes no
  decisions, because a detector that guessed your build command would be wrong
  silently and "verify passed" would stop meaning anything.
- `lib/setup-status.sh` — reports which setup steps already left a trace: labels,
  variable and secret *names*, and whether the workflows reached the default
  branch. Never reads a secret value.

## 0.1.0 — 2026-08-19

First extraction from the repository this grew in.

- `npx avengers-12 init` copies the harness into a repository; `doctor` checks it
- Everything project-specific lives in one `config.yml`
- Claude Code permission rules are derived from `gate.deny`, not written twice
- Verified end to end against a Node project, which is not the kind of project
  it was written in

Known limits:

- The logic is bash and python. npm is delivery, not runtime.
- The runner needs `bash`, `jq` and `python3`. Windows runners are untested.
- One real consumer so far, plus the scratch project in `test/install.sh`.
