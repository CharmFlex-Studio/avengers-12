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

// Written once and then owned by you. Never overwritten, --force or not.
const YOURS = [["templates/config.yml", "avengers-12/config.yml"]];

// Created empty so the first run has somewhere to write.
const STATE_FILES = [
  ["avengers-12/state/STATE.md", "# Loop State\n\nNo run yet.\n"],
  ["avengers-12/state/run-log.md", "# Loop Run Log\n\n"],
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

  for (const [fromRel, toRel] of YOURS) {
    place(path.join(packageRoot, fromRel), toRel, { protectedFile: true });
  }

  for (const [toRel, body] of STATE_FILES) {
    const toAbs = path.join(targetRoot, toRel);
    if (fs.existsSync(toAbs)) {
      report.skipped.push(toRel);
      continue;
    }
    if (!dryRun) {
      fs.mkdirSync(path.dirname(toAbs), { recursive: true });
      fs.writeFileSync(toAbs, body);
    }
    report.created.push(toRel);
  }

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
      "avengers-12/config.yml is never replaced — it is yours once you edit it.",
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
