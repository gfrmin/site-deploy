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
              │ ff-only pull ▸ uv sync ▸ (tailwindcss if static/src.css) ▸ systemctl reload|restart ▸ cf-purge
              ▼  live within ~2 min
```

`bin/auto-deploy.sh` is byte-identical on every box; per-app differences come from a few `DEPLOY_*`
vars in `/etc/<app>/env`. The CSS build is auto-detected by the presence of `static/src.css`.

**Snapshot-backed apps:** if a deploy changes `data/build_db.py` and `DEPLOY_BUILD_SERVICE` is set,
the poller dispatches that build unit (rebuild the snapshot, then reload onto the new code + schema
together via its `--reload-service`) instead of a bare reload — which would 500 against a stale
schema. This is gap-free: the running workers keep serving the old code + old snapshot until the
build's atomic swap.

**Safety:** fast-forward only, with an ancestor check that bails loudly on a drifted or ahead box
(rather than reload-looping), and it **never reloads if `uv sync` or the CSS build fails** — the old
workers keep serving.

## Layout
```
bin/auto-deploy.sh   generic poller (run by the timer, as the service user)
bin/cf-purge.sh      Cloudflare edge purge (no-op unless CF_* set in /etc/<app>/env)
bin/install.sh       install units + sudoers grant + enable the timer (run by an admin, once)
systemd/site-deploy@.service , site-deploy@.timer   shared instance units
example.env          the per-app DEPLOY_* knobs to append to /etc/<app>/env
```

## Per-app config (`/etc/<app>/env`, box-local — never in this repo)
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

## Notes
- **No secrets in this repo.** Per-site tokens and knobs stay in `/etc/<app>/env` on each box.
- It doesn't replace a nightly snapshot-rebuild timer if you have one — they're independent.
- Requires: the box's `/srv/<app>` is a git checkout that can `git fetch` non-interactively (a
  read-only deploy key), a `uv` at `/usr/local/bin/uv`, and (for `reload`) an `ExecReload` in the
  app's own `.service`.
- Disable on a box: `sudo systemctl disable --now site-deploy@<app>.timer`.
