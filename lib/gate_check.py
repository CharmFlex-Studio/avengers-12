#!/usr/bin/env python3
"""Match changed files against the denylist in avengers-12/config.yml.

Kept separate from check-gate.sh because glob semantics are the one part of the
gate that is genuinely fiddly: `**` has to cross directory boundaries while `*`
must not, and getting that subtly wrong is how a denylist quietly stops denying.

The config is read through config.py, which parses a small YAML subset rather
than depending on PyYAML or yq: neither is guaranteed on a GitHub-hosted runner,
and the format is one we control.

Usage:
    gate_check.py <config.yml> <changed-files-file>
    gate_check.py --list-denied <config.yml> <changed-files-file>

Exit codes:
    0  every changed file is allowed, and the count is within budget
    1  at least one violation (printed to stdout, one per line)
    2  the config could not be read -- treated as a violation by the caller

--list-denied prints ONLY the denied paths, one bare path per line, and always
exits 0 unless the gate cannot be parsed. It exists so a shell script can act on
the denied set -- strip-denied.sh reverts those paths before they are committed
to a saved branch. Scraping the human-readable "path  ->  denied by 'x'" lines
for that would break the first time the message is reworded, and the file-count
violation has no path in it at all.
"""

from __future__ import annotations

import os
import re
import sys
from dataclasses import dataclass

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config  # noqa: E402  (sibling module, path set above)


@dataclass(frozen=True)
class Gate:
    denylist: tuple[str, ...]
    allowlist_exceptions: tuple[str, ...]
    max_files_changed: int


def parse_gate(path: str) -> Gate:
    """Read the `gate:` section of config.yml.

    The denylist used to live in its own avengers-12/config.yml with its own flat parser.
    Both are gone: one config file means one place to look, and one parser means
    a fix to the YAML subset benefits every reader of it.

    Fails closed. An empty denylist or a missing file-count is not a permissive
    gate, it is a gate that must stop the run -- the whole point of this file is
    that a run cannot talk its way past it.
    """
    cfg = config.parse(open(path, encoding="utf-8").read())

    deny = config.dig(cfg, "gate.deny") or []
    allow = config.dig(cfg, "gate.allow") or []
    max_files = config.dig(cfg, "gate.maxFilesChanged") or 0

    if not isinstance(deny, list) or not deny:
        raise ValueError(f"{path}: gate.deny is empty or unparseable")
    if not isinstance(allow, list):
        raise ValueError(f"{path}: gate.allow must be a list")
    if not isinstance(max_files, int) or max_files <= 0:
        raise ValueError(f"{path}: gate.maxFilesChanged missing or not a positive integer")

    return Gate(tuple(str(p) for p in deny), tuple(str(p) for p in allow), max_files)


def to_regex(pattern: str) -> re.Pattern[str]:
    """Translate a gitignore-flavoured glob into an anchored regex.

    `**` crosses `/`; `*` and `?` do not. A pattern ending in `/**` also matches
    the directory itself, so `backend/**` blocks `backend/` as well as its files.
    """
    out: list[str] = []
    i = 0
    while i < len(pattern):
        char = pattern[i]
        if char == "*":
            if pattern.startswith("**", i):
                out.append(".*")
                i += 2
                # Collapse `**/` so it also matches zero leading directories.
                if pattern.startswith("/", i):
                    out.append("/?")
                    i += 1
                continue
            out.append("[^/]*")
        elif char == "?":
            out.append("[^/]")
        else:
            out.append(re.escape(char))
        i += 1

    body = "".join(out)
    if pattern.endswith("/**"):
        # `backend/**` -> also match the bare directory path `backend`. Built by
        # recursing on the prefix rather than re.escape-ing it, so a pattern like
        # `**/secrets/**` yields a real glob for `**/secrets` and not a literal
        # match on the two-asterisk string.
        prefix = to_regex(pattern[:-3]).pattern[1:-1]
        body = f"(?:{body}|{prefix})"
    return re.compile(f"^{body}$")


def denied_paths(gate: Gate, files: list[str]) -> list[tuple[str, str]]:
    """Return (path, matching-denylist-pattern) for every denied path."""
    deny = [(p, to_regex(p)) for p in gate.denylist]
    allow = [to_regex(p) for p in gate.allowlist_exceptions]

    found: list[tuple[str, str]] = []
    for path in files:
        if any(rx.match(path) for rx in allow):
            continue
        for pattern, rx in deny:
            if rx.match(path):
                found.append((path, pattern))
                break
    return found


def violations(gate: Gate, files: list[str]) -> list[str]:
    return [f"{path}  ->  denied by '{pattern}'" for path, pattern in denied_paths(gate, files)]


def main(argv: list[str]) -> int:
    list_only = False
    args = argv[1:]
    if args and args[0] == "--list-denied":
        list_only = True
        args = args[1:]

    if len(args) != 2:
        print(__doc__, file=sys.stderr)
        return 2

    gate_path, files_path = args[0], args[1]

    try:
        gate = parse_gate(gate_path)
    except (OSError, ValueError) as exc:
        print(f"gate could not be parsed: {exc}", file=sys.stderr)
        return 2

    with open(files_path, encoding="utf-8") as handle:
        files = [line.strip() for line in handle if line.strip()]

    if list_only:
        for path, _pattern in denied_paths(gate, files):
            print(path)
        return 0

    problems = violations(gate, files)

    if len(files) > gate.max_files_changed:
        problems.append(
            f"{len(files)} files changed  ->  exceeds max_files_changed "
            f"({gate.max_files_changed}); this is not one fix per run"
        )

    for problem in problems:
        print(problem)

    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
