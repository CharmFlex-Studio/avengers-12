"use strict";

// Run the checks. The checks themselves are bash -- this only finds them and
// reports honestly when it cannot.
//
// It deliberately runs the copy in YOUR repository, not the one inside
// node_modules. Those can differ: `init` copied the scripts in, and you may
// have upgraded the package since. Checking the package's own copy would tell
// you the state of a directory nothing runs.

const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const SCRIPT = "avengers-12/lib/doctor.sh";

function run({ targetRoot }) {
  const script = path.join(targetRoot, SCRIPT);

  if (!fs.existsSync(script)) {
    process.stderr.write(
      `no ${SCRIPT} here.\n` +
        `Run \`npx avengers-12 init\` first, or cd to the repository root.\n`
    );
    return 2;
  }

  const result = spawnSync("bash", [script], {
    cwd: targetRoot,
    stdio: "inherit",
  });

  if (result.error) {
    process.stderr.write(`could not run ${SCRIPT}: ${result.error.message}\n`);
    return 2;
  }
  return result.status === null ? 2 : result.status;
}

module.exports = { run };
