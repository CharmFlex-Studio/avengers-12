#!/usr/bin/env python3
"""Compare two configs by shape: same keys, values ignored.

templates/config.yml is what a new project starts from. It is written by hand,
which means it can quietly fall behind the config this project actually runs --
and the failure is silent in the worst possible direction. `permissions.denyRead`
is the example that prompted this file: leave it out of the template and a new
project's coder may read .env, with every check still green.

Values are deliberately NOT compared. The whole point of the template is that
its values differ: your denylist names iosApp/, a new project's does not. Only
the key structure has to match.

Keys that are genuinely optional -- ones the code has a safe default for -- are
listed in OPTIONAL and may be absent from either side.

Usage:
    check_template_shape.py <real.yml> <template.yml>

Exit codes:
    0  same shape
    1  a key is missing from one side
    2  either file could not be read
"""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config  # noqa: E402  (sibling module, path set above)

# Paths allowed to differ. Every one must have a working default in the code,
# so a project that omits it still runs correctly.
OPTIONAL = {
    "gate.allow",
    "runtime.java",
    "runtime.javaDistribution",
    "runtime.cache",
    "runtime.cacheKeyFiles",
    "runtime.chmod",
    "tests.notRun",
    "seed.sources",
    "permissions.allowBash",
}


def shape(node, prefix: tuple[str, ...] = ()) -> set[str]:
    """Every map key as a dotted path. Lists are values, not structure."""
    found: set[str] = set()
    if isinstance(node, dict):
        for key, value in node.items():
            path = prefix + (key,)
            found.add(".".join(path))
            found |= shape(value, path)
    return found


def load(path: str):
    with open(path, encoding="utf-8") as handle:
        return config.parse(handle.read())


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: check_template_shape.py <real.yml> <template.yml>", file=sys.stderr)
        return 2

    real_path, template_path = argv
    try:
        real = shape(load(real_path))
        template = shape(load(template_path))
    except Exception as exc:  # noqa: BLE001 -- any failure is the same answer
        print(f"config: {exc}", file=sys.stderr)
        return 2

    missing_from_template = sorted(real - template - OPTIONAL)
    missing_from_real = sorted(template - real - OPTIONAL)

    for key in missing_from_template:
        print(
            f"{template_path} has no '{key}' -- a new project would start without it",
            file=sys.stderr,
        )
    for key in missing_from_real:
        print(
            f"{real_path} has no '{key}', but the template offers it",
            file=sys.stderr,
        )

    if missing_from_template or missing_from_real:
        return 1

    print(f"template shape matches ({len(real)} keys compared)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
