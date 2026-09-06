#!/usr/bin/env python3
"""Read an app's deploy/site.toml and emit shell assignments for auto-deploy.sh.

Why a file in the app repo rather than more lines in /etc/<app>/env: the env
file lives only on the box. Nothing reviews it, nothing diffs it, and nothing
notices when it drifts — which is exactly how webbsite's committed unit ended up
missing the ExecReload the box had been relying on for months. Config that
decides how a deploy behaves belongs in the repo, next to the code it deploys.

Secrets do NOT move. CF_CACHE_PURGE_TOKEN and friends stay in /etc/<app>/env,
which is not in git and should not be.

Values declared here win over the environment, and a disagreement is reported
rather than silently resolved: a box quietly behaving differently from what the
repo says is the failure this file exists to end.

    eval "$(site-config.py /srv/app/deploy/site.toml)"
"""
from __future__ import annotations

import shlex
import sys
import tomllib
from pathlib import Path

# site.toml key -> the environment variable auto-deploy.sh already reads, so the
# script keeps one way of getting its knobs and this stays a thin adapter.
KEYS = {
    "reload": "DEPLOY_RELOAD",
    "uv_args": "DEPLOY_UV_ARGS",
    "build_service": "DEPLOY_BUILD_SERVICE",
    "health_path": "DEPLOY_HEALTH_PATH",
    "health_match": "DEPLOY_HEALTH_MATCH",
    "health_tries": "DEPLOY_HEALTH_TRIES",
    "css_min_ratio": "DEPLOY_CSS_MIN_RATIO",
    "port": "PORT",
    "cf_zone_id": "CF_ZONE_ID",
}


def render(config: dict, environ: dict) -> list[str]:
    """Return `export VAR=value` lines, plus warnings for anything it overrides."""
    lines, warnings = [], []
    deploy = config.get("deploy", {})
    for key, var in KEYS.items():
        if key not in deploy:
            continue
        value = deploy[key]
        value = "" if value is None else str(value)
        existing = environ.get(var)
        if existing is not None and existing != value:
            warnings.append(
                f"site.toml sets {var}={value!r} but the environment says {existing!r} "
                f"— using site.toml (the repo is the source of truth)"
            )
        lines.append(f"export {var}={shlex.quote(value)}")
    # shlex.quote the whole message: the warnings embed repr()'d values, whose
    # own quotes would otherwise close the echo and inject shell.
    return [f"echo {shlex.quote('auto-deploy: ' + w)} >&2" for w in warnings] + lines


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: site-config.py <path to site.toml>", file=sys.stderr)
        return 2
    path = Path(argv[1])
    if not path.is_file():
        return 0  # no site.toml is fine — the app keeps its knobs in /etc/<app>/env
    try:
        config = tomllib.loads(path.read_text())
    except (tomllib.TOMLDecodeError, OSError) as exc:
        # Report on stderr and fail as a PROCESS. Emitting `exit 1` into the
        # script instead would run in the caller's shell via eval and kill it
        # outright, which took the caller's own error handling out of the
        # picture — including its deliberate choice to survive this before the
        # merge so a repair commit can land.
        print(f"{path} is unreadable: {exc}", file=sys.stderr)
        return 1
    import os
    print("\n".join(render(config, dict(os.environ))))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
