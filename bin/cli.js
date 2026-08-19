#!/usr/bin/env node
"use strict";

// avengers-12 — command line entry point.
//
// This is a thin dispatcher on purpose. The harness itself is still bash and
// python (see ../README.md); npm is how it reaches a repository, not what runs
// it. Every command here either copies files or shells out to lib/.

const path = require("node:path");
const { name, version } = require("../package.json");

const COMMANDS = {
  init: "Copy the harness into this repository",
  doctor: "Check that this installation agrees with itself",
  version: "Print the version",
  help: "Print this message",
};

function usage() {
  const lines = [
    `${name} ${version}`,
    "",
    "Usage:",
    `  npx ${name} <command> [options]`,
    "",
    "Commands:",
  ];
  for (const [cmd, blurb] of Object.entries(COMMANDS)) {
    lines.push(`  ${cmd.padEnd(9)} ${blurb}`);
  }
  lines.push(
    "",
    "Options for init:",
    "  --force    Overwrite files that already exist (never touches config.yml)",
    "  --dry-run  Print what would happen and change nothing",
    "",
    "After init:",
    "  1. edit avengers-12/config.yml    — the only file you must change",
    `  2. npx ${name} doctor         — until it is quiet`,
    "  3. read avengers-12/docs/setup.md — tokens, labels, board",
    ""
  );
  return lines.join("\n");
}

function main(argv) {
  const [command = "help", ...rest] = argv;

  switch (command) {
    case "init":
      return require("./commands/init.js").run({
        packageRoot: path.resolve(__dirname, ".."),
        targetRoot: process.cwd(),
        force: rest.includes("--force"),
        dryRun: rest.includes("--dry-run"),
      });

    case "doctor":
      return require("./commands/doctor.js").run({
        targetRoot: process.cwd(),
      });

    case "version":
    case "--version":
    case "-v":
      process.stdout.write(`${version}\n`);
      return 0;

    case "help":
    case "--help":
    case "-h":
      process.stdout.write(`${usage()}\n`);
      return 0;

    default:
      process.stderr.write(`unknown command: ${command}\n\n${usage()}\n`);
      return 2;
  }
}

process.exitCode = main(process.argv.slice(2));
