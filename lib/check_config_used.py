#!/usr/bin/env python3
"""Find config keys that nothing reads.

A key in config.yml that no script mentions is worse than a missing one: it
reads as configurable, and it is not. Four of them shipped in the first version
of this layout -- `runtime.cacheKeyFiles`, `board.statusField`, `board.optional`
and `tests.notRun` -- and every one was only found by grepping by hand.

The test is deliberately crude: does the dotted path appear, as text, anywhere
in the harness's scripts, workflows, skills or subagents? That is how every real
reader spells it (`cfg board.statusField`, `config.dig(cfg, "gate.deny")`,
`tests.notRun` in a brief template), so a miss means nobody reads it.

It is a tripwire, not a proof. It cannot tell a live reference from one buried
in a comment. It catches the thing that actually happens: a key added to
config.yml and never wired up.

Usage:
    check_config_used.py [config.yml]

Exit codes:
    0  every key is mentioned somewhere
    1  at least one key is unread (names them on stderr)
    2  the config could not be read
"""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config  # noqa: E402  (sibling module, path set above)

# Where a reader could live. Relative to the repository root.
SEARCH_ROOTS = (
    "avengers-12/lib",
    ".github/workflows",
    ".claude/skills",
    ".claude/agents",
)

SKIP_DIRS = {"__pycache__", ".git"}


def dotted_paths(node, prefix: tuple[str, ...] = ()) -> list[str]:
    """Every map key in the config, as a dotted path. List contents are values,
    not keys, so they are not walked."""
    found: list[str] = []
    if isinstance(node, dict):
        for key, value in node.items():
            path = prefix + (key,)
            found.append(".".join(path))
            found.extend(dotted_paths(value, path))
    return found


def haystack() -> str:
    chunks: list[str] = []
    for root in SEARCH_ROOTS:
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            for name in filenames:
                full = os.path.join(dirpath, name)
                try:
                    with open(full, encoding="utf-8", errors="ignore") as handle:
                        chunks.append(handle.read())
                except OSError:
                    continue
    return "\n".join(chunks)


def main(argv: list[str]) -> int:
    path = argv[0] if argv else config.DEFAULT_PATH
    try:
        cfg = config.parse(open(path, encoding="utf-8").read())
    except Exception as exc:  # noqa: BLE001 -- any failure is the same answer
        print(f"config: {exc}", file=sys.stderr)
        return 2

    present = [root for root in SEARCH_ROOTS if os.path.isdir(root)]
    if not present:
        # Run from the wrong directory. Saying "nothing reads any key" would be
        # a false alarm far louder than the real one this check exists for.
        print(
            "cannot check: none of "
            + ", ".join(SEARCH_ROOTS)
            + " exist here -- run from the repository root",
            file=sys.stderr,
        )
        return 2

    blob = haystack()
    unread = [p for p in dotted_paths(cfg) if p not in blob]

    if unread:
        for key in unread:
            print(f"nothing reads {key}", file=sys.stderr)
        return 1

    print(f"every config key is read ({len(dotted_paths(cfg))} checked)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
