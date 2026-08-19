#!/usr/bin/env python3
"""Read avengers-12/config.yml and print it as JSON.

Why not PyYAML: it is not guaranteed on a GitHub-hosted runner, and installing
it would add a step to every job for a file format we control. gate_check.py
already parses its own YAML for the same reason; this is the same trade, made
once and shared.

The supported subset is deliberately small:

    key: value              scalars: string, int, bool, null
    key:                    nested maps, by indentation
      inner: value
    key: [a, b]             inline list of scalars
    key:                    block list of scalars
      - a
      - b
    key:                    block list of maps
      - name: x
        run: y

Anything outside that raises, loudly, with the line number. A config that
cannot be read must never degrade to an empty config -- that would silently
turn the denylist off.

Usage:
    config.py [path]              print the whole config as JSON
    config.py --get a.b.c [path]  print one scalar, or nothing when absent
    config.py --check [path]      validate and print a one-line summary

Exit codes:
    0  parsed (and, for --check, valid)
    2  could not parse, or failed validation
"""

from __future__ import annotations

import json
import sys

DEFAULT_PATH = "avengers-12/config.yml"


class ConfigError(Exception):
    pass


def _scalar(raw: str, lineno: int):
    """Turn a YAML scalar into a Python value."""
    text = raw.strip()
    if text.startswith(("'", '"')) and len(text) >= 2 and text[0] == text[-1]:
        return text[1:-1]

    # An inline list: [a, b, c]
    if text.startswith("[") and text.endswith("]"):
        inner = text[1:-1].strip()
        if not inner:
            return []
        return [_scalar(part, lineno) for part in inner.split(",")]

    # An inline map: { a: 1, b: 2 }
    if text.startswith("{") and text.endswith("}"):
        inner = text[1:-1].strip()
        if not inner:
            return {}
        out = {}
        for part in inner.split(","):
            if ":" not in part:
                raise ConfigError(f"line {lineno}: '{part.strip()}' is not key: value")
            k, v = part.split(":", 1)
            out[k.strip()] = _scalar(v, lineno)
        return out

    low = text.lower()
    if low in ("true", "yes"):
        return True
    if low in ("false", "no"):
        return False
    if low in ("null", "~", ""):
        return None
    if text.lstrip("-").isdigit():
        return int(text)
    return text


def _strip_comment(raw: str) -> str:
    """Drop a trailing # comment that is not inside quotes."""
    out, quote = [], None
    for i, ch in enumerate(raw):
        if quote:
            out.append(ch)
            if ch == quote:
                quote = None
            continue
        if ch in "'\"":
            quote = ch
            out.append(ch)
            continue
        if ch == "#" and (i == 0 or raw[i - 1] in " \t"):
            break
        out.append(ch)
    return "".join(out)


def _lines(text: str):
    """Yield (lineno, indent, content) for every meaningful line."""
    for lineno, raw in enumerate(text.splitlines(), start=1):
        if "\t" in raw[: len(raw) - len(raw.lstrip())]:
            raise ConfigError(f"line {lineno}: tab used for indentation; use spaces")
        stripped = _strip_comment(raw).rstrip()
        if not stripped.strip():
            continue
        yield lineno, len(stripped) - len(stripped.lstrip()), stripped.strip()


def parse(text: str):
    items = list(_lines(text))

    def block(pos: int, indent: int):
        """Parse one block at `indent`. Returns (value, next position)."""
        if pos >= len(items):
            return None, pos

        _, first_indent, first = items[pos]
        if first.startswith("- "):
            return sequence(pos, first_indent)
        return mapping(pos, indent)

    def mapping(pos: int, indent: int):
        out = {}
        while pos < len(items):
            lineno, ind, content = items[pos]
            if ind < indent:
                break
            if ind > indent:
                raise ConfigError(f"line {lineno}: unexpected indentation")
            if content.startswith("- "):
                break
            if ":" not in content:
                raise ConfigError(f"line {lineno}: '{content}' is not key: value")

            key, rest = content.split(":", 1)
            key, rest = key.strip(), rest.strip()
            pos += 1

            if rest:
                out[key] = _scalar(rest, lineno)
                continue

            # Value is a nested block, or nothing.
            if pos < len(items) and items[pos][1] > ind:
                out[key], pos = block(pos, items[pos][1])
            elif pos < len(items) and items[pos][1] == ind and items[pos][2].startswith("- "):
                # A block list written at the parent's indentation. Legal YAML.
                out[key], pos = sequence(pos, ind)
            else:
                out[key] = None
        return out, pos

    def sequence(pos: int, indent: int):
        out = []
        while pos < len(items):
            lineno, ind, content = items[pos]
            if ind < indent or not content.startswith("- "):
                break
            if ind > indent:
                raise ConfigError(f"line {lineno}: unexpected indentation in list")

            body = content[2:].strip()
            pos += 1

            # "- key: value" starts a map that may continue on later lines.
            if ":" in body and not body.startswith(("'", '"', "[", "{")):
                key, rest = body.split(":", 1)
                entry = {key.strip(): _scalar(rest, lineno) if rest.strip() else None}
                while pos < len(items) and items[pos][1] > ind and not items[pos][2].startswith("- "):
                    lineno2, _, more = items[pos]
                    if ":" not in more:
                        raise ConfigError(f"line {lineno2}: '{more}' is not key: value")
                    k, v = more.split(":", 1)
                    entry[k.strip()] = _scalar(v, lineno2) if v.strip() else None
                    pos += 1
                out.append(entry)
            else:
                out.append(_scalar(body, lineno))
        return out, pos

    value, pos = block(0, items[0][1] if items else 0)
    if pos != len(items):
        raise ConfigError(f"line {items[pos][0]}: could not parse from here")
    return value or {}


# --- validation --------------------------------------------------------------
# Fails closed. A config missing its gate is not "a config with no denylist";
# it is a config that must stop the run.
# The format this parser understands. A config written for a later avengers-12
# may use keys this code has never heard of, and the failure mode of ignoring
# them is silent: a denylist entry or a verify step that simply does not happen.
# Refusing is the only safe answer.
SUPPORTED_VERSION = 1

REQUIRED = [
    ("version", int),
    ("gate", dict),
    ("gate.deny", list),
    ("gate.maxFilesChanged", int),
    ("verify", list),
    ("labels", dict),
    ("branch", dict),
    ("budget", dict),
    ("models", dict),
    ("paths", dict),
]


def dig(cfg, dotted: str):
    node = cfg
    for part in dotted.split("."):
        if not isinstance(node, dict) or part not in node:
            return None
        node = node[part]
    return node


def validate(cfg) -> list[str]:
    problems = []
    for dotted, kind in REQUIRED:
        value = dig(cfg, dotted)
        if value is None:
            problems.append(f"missing: {dotted}")
        elif not isinstance(value, kind):
            problems.append(f"{dotted} should be {kind.__name__}, got {type(value).__name__}")

    version = dig(cfg, "version")
    if isinstance(version, int) and version != SUPPORTED_VERSION:
        problems.append(
            f"version {version} is not supported by this avengers-12 "
            f"(it reads version {SUPPORTED_VERSION}) -- upgrade the harness or the config"
        )

    if not dig(cfg, "gate.deny"):
        problems.append("gate.deny is empty — the gate would allow every path")

    house_rules = dig(cfg, "houseRules")
    if house_rules is not None and not isinstance(house_rules, list):
        problems.append("houseRules should be a list of file paths")

    for i, step in enumerate(dig(cfg, "verify") or []):
        if not isinstance(step, dict):
            problems.append(f"verify[{i}] should be a map with name and run")
            continue
        for field in ("name", "run"):
            if not step.get(field):
                problems.append(f"verify[{i}] is missing '{field}'")
    return problems


def main(argv: list[str]) -> int:
    args = list(argv)
    mode, key = "json", None
    if args and args[0] == "--get":
        mode, key = "get", args[1]
        args = args[2:]
    elif args and args[0] == "--check":
        mode = "check"
        args = args[1:]

    path = args[0] if args else DEFAULT_PATH

    try:
        with open(path, encoding="utf-8") as handle:
            cfg = parse(handle.read())
    except (OSError, ConfigError) as exc:
        print(f"config: {exc}", file=sys.stderr)
        return 2

    problems = validate(cfg)

    if mode == "check":
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        if problems:
            print(f"config: {len(problems)} problem(s) in {path}", file=sys.stderr)
            return 2
        deny = len(dig(cfg, "gate.deny") or [])
        steps = len(dig(cfg, "verify") or [])
        print(f"config ok: {deny} denied path(s), {steps} verify step(s)")
        return 0

    if problems:
        for problem in problems:
            print(f"config: {problem}", file=sys.stderr)
        return 2

    if mode == "get":
        value = dig(cfg, key)
        if value is None:
            return 0
        print(value if isinstance(value, str) else json.dumps(value))
        return 0

    print(json.dumps(cfg, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
