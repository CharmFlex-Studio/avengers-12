# Changelog

## 0.1.0 — unreleased

First extraction from the repository this grew in.

- `npx avengers-12 init` copies the harness into a repository; `doctor` checks it
- Everything project-specific lives in one `config.yml`
- Claude Code permission rules are derived from `gate.deny`, not written twice
- `/setup-workflow` skill: writes config.yml from the project, creates labels, and
  reports the browser-only steps it cannot do
- Verified end to end against a Node project, which is not the kind of project
  it was written in

Known limits:

- The logic is bash and python. npm is delivery, not runtime.
- The runner needs `bash`, `jq` and `python3`. Windows runners are untested.
- One real consumer so far, plus the scratch project in `test/install.sh`.
