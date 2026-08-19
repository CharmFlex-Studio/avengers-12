#!/usr/bin/env python3
"""Print a cache key derived from the files named by `runtime.cacheKeyFiles`.

Actions has `hashFiles()`, and it cannot be used here: its globs must be
literals in the workflow file, and a literal in loop.yml is the exact thing this
refactor exists to remove. So loop.yml used to hash a hardcoded list of Gradle,
npm and Go manifests while `runtime.cacheKeyFiles` sat in config.yml doing
nothing at all -- a key that reads as configurable and is not.

The glob translation is imported from gate_check.py, the same way match_paths.py
does it, so `**` crosses directories and `*` does not everywhere in the harness.
One parser, one meaning for a path pattern.

Only tracked files are considered. An untracked build artifact must never move
the cache key, or the cache never hits.

Usage:
    cache_key.py [config.yml]

Prints a 16-character hex digest, or `none` when no pattern is configured.
Exit 0 always: a cache key is an optimisation, and failing to compute one must
never fail the job. On error it prints `nokey-<reason>`, which simply misses.
"""

from __future__ import annotations

import hashlib
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config  # noqa: E402  (sibling module, path set above)
import gate_check  # noqa: E402


def tracked_files() -> list[str]:
    out = subprocess.run(
        ["git", "ls-files", "-z"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    return [p for p in out.split("\0") if p]


def main(argv: list[str]) -> int:
    path = argv[0] if argv else config.DEFAULT_PATH
    try:
        cfg = config.parse(open(path, encoding="utf-8").read())
    except Exception:
        print("nokey-unreadable-config")
        return 0

    patterns = config.dig(cfg, "runtime.cacheKeyFiles") or []
    if not isinstance(patterns, list) or not patterns:
        print("none")
        return 0

    try:
        files = tracked_files()
    except Exception:
        print("nokey-no-git")
        return 0

    regexes = [gate_check.to_regex(str(p)) for p in patterns]
    matched = sorted(f for f in files if any(rx.match(f) for rx in regexes))

    # The pattern list is hashed too, so editing config.yml invalidates the
    # cache even when the set of matched files happens not to change.
    digest = hashlib.sha256()
    for pattern in patterns:
        digest.update(f"pattern:{pattern}\0".encode())
    for name in matched:
        digest.update(f"file:{name}\0".encode())
        try:
            with open(name, "rb") as handle:
                for chunk in iter(lambda: handle.read(65536), b""):
                    digest.update(chunk)
        except OSError:
            digest.update(b"unreadable\0")

    print(digest.hexdigest()[:16])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
