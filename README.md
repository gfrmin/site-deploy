# site-deploy

Git **push-to-deploy** for a small fleet of sibling sites that share one shape: a `uv`-managed
Python app (FastAPI/Flask) run by gunicorn under systemd, checked out at `/srv/<app>` and pulling
`master`. One shared, parameterized toolkit instead of a copy of the deploy glue per repo.

## Why
A common self-hosted setup has no auto-deploy: pushing to `master` does nothing until someone SSHes
in and runs `git pull && uv sync && (tailwindcss) && systemctl reload` by hand — so boxes silently
drift behind `origin`. This closes that gap with **no CI, no webhook, and no inbound exposure**.

## How it works
Each box runs a tiny systemd **instance** timer that polls `origin/master` every ~2 min (as the
service user, over the box's existing read-only git deploy key) and self-deploys if it moved. The
instance name `%i` is the app, which is also the service user, `/srv/%i`, and `/etc/%i/env`, so a
single unit template covers every app with no per-app rendering.

```
git push ─▶ origin/master
                ▲ git fetch (every ~2 min, as the service user)
        site-deploy@<app>.timer ─▶ site-deploy@<app>.service ─▶ bin/auto-deploy.sh
              │ ff-only pull ▸ uv sync ▸ (css, canaried) ▸ reload ▸ HEALTH ▸ cf-purge
              ▼  live within ~2 min
```

`bin/auto-deploy.sh` is byte-identical on every box; per-app differences come from
**`deploy/site.toml` in the app's own repo** (see below), falling back to `DEPLOY_*` vars in
`/etc/<app>/env`. The CSS build is auto-detected by the presence of `static/src.css`.

**A deploy is not finished when the merge lands — it is finished when the new code is reloaded and
answering.** The reload is gated on a health probe, and the edge purge is gated on that probe
passing, because purging before the origin serves the new code just refills the edge from stale, or
from a 500. If anything between the merge and a healthy reload fails, a marker file makes the next
tick resume rather than see "up to date" and quietly turn the failed unit green.

**Snapshot-backed apps:** if a deploy changes `data/build_db.py` and `DEPLOY_BUILD_SERVICE` is set,
the poller reloads onto the new code **immediately** and *also* dispatches that build unit (rebuild
the snapshot, then re-reload + re-purge via its `--reload-service`). The reload can't be deferred:
Jinja reads templates from disk, so once the pull lands the old workers are already rendering the
new templates — old Python under new templates 500s on any template that needs new Python (live
incident, crescira 2026-07-12). The app-side contract that makes the early reload safe: new code
must degrade gracefully on the previous snapshot schema (feature-detect new tables/columns rather
than assuming them).

**Safety:** fast-forward only, with an ancestor check that bails loudly on a drifted or ahead box
(rather than reload-looping), and it **never reloads if `uv sync` or the CSS build fails** — the old
workers keep serving.

## Provisioning a new box

```
host/cloud-init.yaml    first boot: admin user + Tailscale, nothing else
host/provision.sh <app> packages, uv, service user, 4G swap + vm.swappiness=10
host/harden.sh          key-only sshd + ufw (tailnet + Cloudflare ranges only)
```

**Confirm `ssh g@<box>` works over Tailscale SSH before running `harden.sh`.** It closes public
`:22`, and doing that first is a live lockout needing the provider's recovery console.

The host layer is promoted from dataguru's `deploy/host/`, which had absorbed the incident fixes.
What stayed behind is the part that is genuinely dataguru-shaped: a uv *workspace* of four apps
under one lock, and `/etc/dataguru/apps`.

## Layout
```
bin/auto-deploy.sh   generic poller (run by the timer, as the service user)
bin/cf-purge.sh      Cloudflare edge purge (no-op unless CF_* set in /etc/<app>/env)
bin/install.sh       install units + sudoers grant + enable the timer (run by an admin, once)
systemd/site-deploy@.service , site-deploy@.timer   shared instance units
example.env          the per-app DEPLOY_* knobs to append to /etc/<app>/env
```

## Per-app config: `deploy/site.toml` in the app repo

The knobs that decide how a deploy behaves belong next to the code they deploy, where a pull request
can review them. They used to live only in `/etc/<app>/env` on the box — which nothing diffs, and
where nothing notices drift. That is how webbsite's committed systemd unit ended up missing an
`ExecReload` the box had been relying on for months.

```toml
[deploy]
reload       = "reload"            # or "restart" for a unit with no ExecReload
uv_args      = "--frozen --no-dev"
port         = 8000
health_path  = "/health"           # probed on 127.0.0.1:$port after the reload
health_match = '"ok"'              # a 200 from a half-booted worker is not health
cf_zone_id   = "..."               # non-secret half of the purge
# build_service = "<app>-build.service"   # snapshot-backed apps only
```

`site.toml` wins over the environment, and a disagreement is **reported**, not silently resolved —
a box quietly behaving differently from the repo is the failure this exists to end. It is read
twice: once before the fetch (for knobs needed to decide what to do) and again after the merge, so
a commit that changes it governs its own deploy rather than the next one. A malformed file is fatal
*after* the merge and merely a warning before it, or the file that breaks the deploy would deadlock
the very commit that fixes it.

## Secrets (`/etc/<app>/env`, box-local — never in this repo)
```
DEPLOY_RELOAD=reload               # or: restart   (apps with no ExecReload)
DEPLOY_UV_ARGS=--frozen --no-dev   # or just: --frozen
# DEPLOY_BUILD_SERVICE=<app>-build.service   # snapshot-backed apps only (see above)
# CF_ZONE_ID=... / CF_CACHE_PURGE_TOKEN=...   # optional edge purge
```

## Bootstrap (per box, one-time)
```bash
APP=<app>
# 1. Clone the toolkit next to the app checkout, owned by the service user.
sudo install -d -o "$APP" -g "$APP" /srv/site-deploy
sudo -u "$APP" git clone <this-repo-url> /srv/site-deploy
#    (private fork? clone over SSH with a read-only deploy key, like the app repo.)

# 2. Add the DEPLOY_* knobs (see example.env) to /etc/$APP/env.

# 3. Install + enable. The first tick deploys whatever the box is behind by.
/srv/site-deploy/bin/install.sh "$APP"
journalctl -fu "site-deploy@$APP.service"
```
Toolkit updates land automatically — `auto-deploy.sh` self-pulls `/srv/site-deploy` each tick
(silent best-effort).

## Tests

```sh
./tests/test-auto-deploy.sh
```

No network, no root, no systemd, no Cloudflare: a throwaway bare git origin stands in for GitHub,
and `systemctl`/`uv`/`curl` are stubs on `PATH` that record their arguments and can be told to fail.
Runs continue from each other's state, so idempotence is a real assertion.

Every guard is verified **by mutation** — break it and watch the named check fail. That is not a
formality: it caught that the CSS floor and ratio guards overlapped, so a single collapse scenario
pinned neither, and both could be deleted with the suite still green.

## Notes
- **No secrets in this repo.** Per-site tokens and knobs stay in `/etc/<app>/env` on each box.
- It doesn't replace a nightly snapshot-rebuild timer if you have one — they're independent.
- Requires: the box's `/srv/<app>` is a git checkout that can `git fetch` non-interactively (a
  read-only deploy key), a `uv` at `/usr/local/bin/uv`, and (for `reload`) an `ExecReload` in the
  app's own `.service`.
- Disable on a box: `sudo systemctl disable --now site-deploy@<app>.timer`.
