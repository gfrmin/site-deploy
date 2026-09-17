#!/usr/bin/env python3
"""Read an app's deploy/site.toml [converge] table for bin/converge.sh.

Emits one line per fact, FS-separated (ASCII Unit Separator, 0x1F), so a
bash script can build arrays without invoking python per lookup:

    FILE<FS><src><FS><dst><FS><validate><FS><unit><FS><apply>
    ACTIVE<FS><unit>
    ENABLE_TIMERS<FS>1
    PRUNE<FS>1

0x1F, not a tab: bash's `read -r` with `IFS=$'\t'` COLLAPSES consecutive
delimiters, because tab is one of the three characters (space/tab/newline)
bash treats as "IFS whitespace" and merges runs of on both sides -- so an
empty field (validate="" or unit="") shifts every later field left instead
of reading back as empty. 0x1F is not whitespace to bash, so empty fields
round-trip exactly. Verified: a two-field-empty row silently misparsed with
tabs and did not with this.

No [converge] table (or no site.toml at all) prints nothing and exits 0 --
an app with its own deploy/converge.sh, or with none at all, is not an
error, the same convention bin/site-config.py uses for a missing file.

A malformed [converge] table exits 1 with the reason on stderr: converge is
safety-critical, and a script that silently treated "malformed" the same as
"absent" would proceed with none of what the app actually declared.
"""
from __future__ import annotations

import sys
import tomllib
from pathlib import Path

VALID_APPLY = {"reload", "restart", "daemon-reload"}
VALID_VALIDATE = {"", "caddy", "systemd-analyze", "visudo"}
FS = "\x1f"


def parse(config: dict, path: Path) -> list[str] | None:
    """-> lines to print, or None (with a message on stderr) if malformed."""
    conv = config.get("converge")
    if conv is None:
        return []

    lines = []
    for i, f in enumerate(conv.get("files", [])):
        for req in ("src", "dst"):
            if req not in f:
                print(f"{path}: converge.files[{i}] missing required key {req!r}", file=sys.stderr)
                return None
        apply_ = f.get("apply", "")
        if apply_ and apply_ not in VALID_APPLY:
            print(f"{path}: converge.files[{i}] apply={apply_!r} not one of {sorted(VALID_APPLY)}",
                  file=sys.stderr)
            return None
        validate = f.get("validate", "")
        if validate not in VALID_VALIDATE:
            print(f"{path}: converge.files[{i}] validate={validate!r} not one of {sorted(VALID_VALIDATE)}",
                  file=sys.stderr)
            return None
        unit = f.get("unit", "")
        if apply_ in ("reload", "restart") and not unit:
            print(f"{path}: converge.files[{i}] apply={apply_!r} requires 'unit'", file=sys.stderr)
            return None
        for v in (f["src"], f["dst"], validate, unit, apply_):
            if FS in v or "\n" in v:
                print(f"{path}: converge.files[{i}] a value contains the field separator or a newline",
                      file=sys.stderr)
                return None
        lines.append(FS.join(("FILE", f["src"], f["dst"], validate, unit, apply_)))

    for u in conv.get("ensure_active", []):
        lines.append(f"ACTIVE{FS}{u}")
    if conv.get("enable_timers"):
        lines.append(f"ENABLE_TIMERS{FS}1")
    if conv.get("prune"):
        lines.append(f"PRUNE{FS}1")
    return lines


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: converge-config.py <path to site.toml>", file=sys.stderr)
        return 2
    path = Path(argv[1])
    if not path.is_file():
        return 0
    try:
        config = tomllib.loads(path.read_text())
    except (tomllib.TOMLDecodeError, OSError) as exc:
        print(f"{path}: {exc}", file=sys.stderr)
        return 1
    lines = parse(config, path)
    if lines is None:
        return 1
    if lines:
        print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
