#!/usr/bin/env python3
"""Read a site's deploy/site.toml and emit shell assignments for auto-deploy.sh.

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

Workspace mode (Phase D item 14: several apps served from one checkout) adds
two more things this file understands:

  --app-keys   render only the per-app subset of [deploy] — the site-wide
               knobs (deploy_ref, uv_args, tailwindcss_version, converge) make
               no sense in an app's OWN site.toml (one checkout has one ref,
               one venv, one converge decision), so a workspace app's file
               declaring one is reported and ignored rather than silently
               read. Used against <apps_dir>/<app>/deploy/site.toml.

  [workspace]  a SITE-level table (never rendered under --app-keys), read
               from the site's own deploy/site.toml:
                 apps_dir     = "apps"                  # where members live
                 shared       = ["packages/"]           # reloads every app
                 build_inputs = ["packages/x/src/"]     # rebuilds every app
"""
from __future__ import annotations

import shlex
import sys
import tomllib
from pathlib import Path

# site.toml [deploy] key -> the environment variable auto-deploy.sh reads.
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
    "cf_domain": "CF_DOMAIN",
    "converge": "DEPLOY_CONVERGE",
    "tailwindcss_version": "TAILWINDCSS_VERSION",
    "deploy_ref": "DEPLOY_REF",
    "service": "DEPLOY_SERVICE",
    "build_inputs": "DEPLOY_BUILD_INPUTS",
}

# One checkout has one ref, one venv, one converge decision — these four are
# meaningless in a workspace app's own site.toml, so --app-keys drops them
# (with a warning, not a silent ignore) rather than letting an app believe it
# controls something only the site can.
SITE_ONLY_KEYS = {"deploy_ref", "uv_args", "tailwindcss_version", "converge"}

# site.toml [workspace] key -> the environment variable lib/workspace.sh reads.
WORKSPACE_KEYS = {
    "apps_dir": "WORKSPACE_APPS_DIR",
    "shared": "WORKSPACE_SHARED",
    "build_inputs": "WORKSPACE_BUILD_INPUTS",
}


def _render_value(value: object) -> str:
    # A list (e.g. `build_inputs = ["data/", "packages/x/"]`) is joined
    # newline-separated: shlex.quote below keeps embedded newlines intact in
    # the exported string, and the shell side reads them back with
    # `while IFS= read -r`.
    if isinstance(value, list):
        return "\n".join(str(v) for v in value)
    return "" if value is None else str(value)


def render(config: dict, environ: dict, app_keys: bool = False) -> list[str]:
    """Return `export VAR=value` lines, plus warnings for anything it overrides."""
    lines, warnings = [], []
    deploy = config.get("deploy", {})
    for key, var in KEYS.items():
        if key not in deploy:
            continue
        if app_keys and key in SITE_ONLY_KEYS:
            warnings.append(
                f"{key!r} is a site-level knob and is ignored in an app's own "
                f"site.toml (set it in the site's deploy/site.toml instead)"
            )
            continue
        value = _render_value(deploy[key])
        existing = environ.get(var)
        if existing is not None and existing != value:
            warnings.append(
                f"site.toml sets {var}={value!r} but the environment says {existing!r} "
                f"— using site.toml (the repo is the source of truth)"
            )
        lines.append(f"export {var}={shlex.quote(value)}")

    if not app_keys:
        workspace = config.get("workspace", {})
        for key, var in WORKSPACE_KEYS.items():
            if key not in workspace:
                continue
            lines.append(f"export {var}={shlex.quote(_render_value(workspace[key]))}")

    # shlex.quote the whole message: the warnings embed repr()'d values, whose
    # own quotes would otherwise close the echo and inject shell.
    return [f"echo {shlex.quote('auto-deploy: ' + w)} >&2" for w in warnings] + lines


def main(argv: list[str]) -> int:
    args = argv[1:]
    app_keys = "--app-keys" in args
    args = [a for a in args if a != "--app-keys"]
    if len(args) != 1:
        print("usage: site-config.py [--app-keys] <path to site.toml>", file=sys.stderr)
        return 2
    path = Path(args[0])
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
    print("\n".join(render(config, dict(os.environ), app_keys=app_keys)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
