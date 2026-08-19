"use strict";

// Copy the harness into the repository you are standing in.
//
// The rule everywhere below: never destroy work. An existing file is skipped
// and reported, not replaced, unless --force says otherwise -- and config.yml
// is never replaced even then, because it is the one file that is genuinely
// yours once you have edited it.

const fs = require("node:fs");
const path = require("node:path");

// [from, to] relative to the package root and the target root.
// Directories are copied whole; files individually.
const DIRECTORIES = [
  ["lib", "avengers-12/lib"],
  ["rules", "avengers-12/rules"],
  ["settings", "avengers-12/settings"],
  ["docs", "avengers-12/docs"],
  ["templates/claude/agents", ".claude/agents"],
  ["templates/claude/skills", ".claude/skills"],
  ["templates/workflows", ".github/workflows"],
  ["templates/ISSUE_TEMPLATE", ".github/ISSUE_TEMPLATE"],
];

// Written once and then owned by the repository. Never overwritten, --force or
// not: config.yml is yours the moment you edit it, and the two state files are
// written by the loop itself from the first run onwards. Replacing either would
// destroy something no copy of this package can reproduce.
//
// Every one of these is a real file in templates/, not a string in this code.
// A default you cannot open and read is a default nobody reviews.
const COPY_ONCE = [
  ["templates/config.yml", "avengers-12/config.yml"],
  ["templates/state/STATE.md", "avengers-12/state/STATE.md"],
  ["templates/state/run-log.md", "avengers-12/state/run-log.md"],
];

function walk(dir, base = "") {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name === "__pycache__" || entry.name === ".DS_Store") continue;
    const rel = path.join(base, entry.name);
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...walk(full, rel));
    else out.push(rel);
  }
  return out;
}

// The harness writes everything it needs during a run into .loop/ — the brief,
// the evidence packet, the generated permission rules, the agent's own notes.
// None of it belongs in your repository.
//
// Left untracked-but-not-ignored it does real damage twice over: `git add -A`
// sweeps ~18 scratch files into the commit, so every draft PR is a huge diff for
// a one-line change; and check-gate counts them as changed files, so the guard
// that refuses a run where the agent produced NOTHING can never fire — an empty
// run passes the gate and opens a PR.
//
// Appended rather than written, so an existing .gitignore is never replaced.
function ensureLoopIgnored(targetRoot, report, dryRun) {
  const rel = ".gitignore";
  const abs = path.join(targetRoot, rel);
  const existing = fs.existsSync(abs) ? fs.readFileSync(abs, "utf8") : "";

  if (existing.split("\n").some((line) => line.trim().replace(/\/$/, "") === ".loop")) {
    report.skipped.push(`${rel} (already ignores .loop/)`);
    return;
  }

  if (!dryRun) {
    const sep = existing === "" || existing.endsWith("\n") ? "" : "\n";
    fs.appendFileSync(
      abs,
      `${sep}\n# avengers-12 scratch space, written fresh every run\n.loop/\n`
    );
  }
  report[existing ? "replaced" : "created"].push(`${rel} (+ .loop/)`);
}

function run({ packageRoot, targetRoot, force, dryRun }) {
  const report = { created: [], skipped: [], replaced: [] };

  const place = (fromAbs, toRel, { protectedFile = false } = {}) => {
    const toAbs = path.join(targetRoot, toRel);
    const exists = fs.existsSync(toAbs);

    if (exists && (protectedFile || !force)) {
      report.skipped.push(toRel);
      return;
    }
    if (!dryRun) {
      fs.mkdirSync(path.dirname(toAbs), { recursive: true });
      fs.copyFileSync(fromAbs, toAbs);
      // Keep the executable bit: every .sh here is run directly by a workflow
      // step, and a copy that loses +x fails with "permission denied" a long
      // way from the thing that caused it.
      const mode = fs.statSync(fromAbs).mode;
      fs.chmodSync(toAbs, mode);
    }
    (exists ? report.replaced : report.created).push(toRel);
  };

  for (const [fromRel, toRel] of DIRECTORIES) {
    const fromAbs = path.join(packageRoot, fromRel);
    if (!fs.existsSync(fromAbs)) continue;
    for (const rel of walk(fromAbs)) {
      place(path.join(fromAbs, rel), path.join(toRel, rel));
    }
  }

  for (const [fromRel, toRel] of COPY_ONCE) {
    place(path.join(packageRoot, fromRel), toRel, { protectedFile: true });
  }

  ensureLoopIgnored(targetRoot, report, dryRun);

  print(report, { dryRun, force });
  return 0;
}

function print(report, { dryRun, force }) {
  const out = [];
  if (dryRun) out.push("DRY RUN — nothing was written.", "");

  const section = (label, items) => {
    if (!items.length) return;
    out.push(`${label} (${items.length}):`);
    for (const item of items.sort()) out.push(`  ${item}`);
    out.push("");
  };

  section("created", report.created);
  section("replaced", report.replaced);
  section("left alone", report.skipped);

  if (report.skipped.length && !force) {
    out.push(
      "Files that already existed were left alone. Pass --force to replace them.",
      "config.yml and state/ are never replaced, --force or not: one is yours once",
      "you edit it, the other two are written by the loop and cannot be regenerated.",
      ""
    );
  }

  out.push(
    "Next:",
    "  1. edit avengers-12/config.yml — the denylist, the verify commands, your test folder",
    "  2. npx avengers-12 doctor      — run it until it is quiet",
    "  3. avengers-12/docs/setup.md   — tokens, labels, the board",
    ""
  );
  process.stdout.write(out.join("\n"));
}

module.exports = { run };
