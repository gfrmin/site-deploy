#!/usr/bin/env python3
"""Read deploy/fleet.toml for lib/workspace.sh's ws_apps() (Phase D item 14).

Prints one hosted app name per line for the given host. Exact `hostname`
match, no fuzzy fallback: the tailnet name and `hostname` can differ, and two
app names can be one letter-order apart (renavon's fleet.json comment).

A host absent from the file prints nothing and exits 0 -- "hosts nothing" is
a legitimate box (or a box not yet added), not an error to fail over on. A
missing fleet.toml is the same: not every site is workspace-hosted. A
MALFORMED file is different and exits 1 with the reason on stderr, because
that must never read the same as "hosts nothing" -- ws_apps() in
lib/workspace.sh treats this file as safety-critical for exactly that reason.

    fleet-config.py deploy/fleet.toml "$(hostname)"
"""
from __future__ import annotations

import sys
import tomllib
from pathlib import Path


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print("usage: fleet-config.py <path to fleet.toml> <hostname>", file=sys.stderr)
        return 2
    path, host = Path(argv[1]), argv[2]
    if not path.is_file():
        return 0  # no fleet.toml at all: this site is not workspace-hosted here
    try:
        config = tomllib.loads(path.read_text())
    except (tomllib.TOMLDecodeError, OSError) as exc:
        print(f"{path}: {exc}", file=sys.stderr)
        return 1
    hosts = config.get("hosts", {})
    if not isinstance(hosts, dict):
        print(f"{path}: top-level 'hosts' is not a table", file=sys.stderr)
        return 1
    entry = hosts.get(host)
    if entry is None:
        return 0
    apps = entry.get("apps") if isinstance(entry, dict) else None
    if apps is None:
        return 0
    if not isinstance(apps, list) or not all(isinstance(a, str) for a in apps):
        print(f"{path}: hosts.{host!r}.apps is not a list of strings", file=sys.stderr)
        return 1
    for app in apps:
        print(app)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
