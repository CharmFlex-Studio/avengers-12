#!/usr/bin/env python3
"""Does any changed path match this glob?

Used by verify.sh for the `when:` filter on a verify step, so an app-only run
does not pay for the backend build.

The glob translation is imported from gate_check.py rather than reimplemented,
and that is the whole point of this file existing. `**` must cross directory
boundaries while `*` must not. Two copies of that rule drift, and when they
drift the `when:` filter and the denylist stop agreeing about what a path
pattern means — which is exactly the kind of quiet disagreement this harness
keeps being bitten by.

Usage:
    match_paths.py <glob> <changed-files-file>

Exit codes:
    0  at least one line in the file matches the glob
    1  nothing matches, or the file is empty or missing
"""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gate_check  # noqa: E402  (sibling module, path set above)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: match_paths.py <glob> <changed-files-file>", file=sys.stderr)
        return 1

    pattern, changed_file = argv
    regex = gate_check.to_regex(pattern)

    try:
        with open(changed_file, encoding="utf-8") as handle:
            for raw in handle:
                line = raw.strip()
                if line and regex.match(line):
                    return 0
    except OSError:
        return 1
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
