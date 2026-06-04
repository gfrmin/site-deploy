#!/usr/bin/env bash
# Poll origin/master for $APP and, if it advanced, fast-forward + rebuild + reload + purge.
#
# Runs as the service user (== $APP) from the systemd timer `site-deploy@$APP.timer`.
# Idempotent: a silent no-op when the box is already current, so a 2-minute cadence is cheap.
#
# Safety: fast-forward only (never clobbers a hand-edited box — it bails loudly on drift/ahead),
# and never reloads if `uv sync` or the CSS build fails (the old workers keep serving). All
# privileged work is one NOPASSWD `systemctl <verb> $APP`.
#
# Per-app knobs come from the unit's EnvironmentFile=/etc/$APP/env:
#   DEPLOY_RELOAD=reload|restart      (default reload; use restart for apps with no ExecReload)
#   DEPLOY_UV_ARGS=--frozen [--no-dev]
#   DEPLOY_BUILD_SERVICE=<app>-build.service  (optional; for apps with a snapshot build — if a
#                                              deploy changes data/build_db.py, rebuild instead of
#                                              a bare reload, which would 500 on a stale schema)
#   CF_ZONE_ID, CF_CACHE_PURGE_TOKEN  (optional; used by bin/cf-purge.sh)
# Override RELOAD_CMD (default `sudo -n /usr/bin/systemctl`) to `echo` for a no-sudo local dry-run.
set -uo pipefail

APP="${APP:?APP env var required (set by site-deploy@.service)}"
SELF="${SITE_DEPLOY_DIR:-/srv/site-deploy}"   # override only for local dry-runs
SRV="${APP_DIR:-/srv/${APP}}"                  # override only for local dry-runs
UV="${UV:-/usr/local/bin/uv}"
RELOAD="${DEPLOY_RELOAD:-reload}"
UV_ARGS="${DEPLOY_UV_ARGS:---frozen}"
RELOAD_CMD="${RELOAD_CMD:-sudo -n /usr/bin/systemctl}"   # override to `echo` for a dry-run
log() { echo "auto-deploy[$APP]: $*"; }

# 0. Self-update the toolkit (best-effort + silent; a toolkit change lands on the NEXT tick).
git -C "$SELF" pull --ff-only --quiet 2>/dev/null || true

cd "$SRV" || { log "no checkout at $SRV"; exit 1; }

# 1. Cheap remote check. A transient fetch failure just retries next tick (exit 0, not failed).
git fetch --quiet origin || { log "fetch failed (transient?); will retry next tick"; exit 0; }
LOCAL=$(git rev-parse @)
REMOTE=$(git rev-parse '@{u}')
[ "$LOCAL" = "$REMOTE" ] && exit 0           # up to date -> silent no-op

# Only deploy when upstream is STRICTLY ahead (local is an ancestor of remote). If local is ahead
# of or diverged from origin, bail loudly rather than reload-looping every tick on a drifted box.
git merge-base --is-ancestor "$LOCAL" "$REMOTE" \
  || { log "local ahead of / diverged from origin (not a clean fast-forward) — manual fix needed"; exit 1; }

log "${LOCAL:0:9} -> ${REMOTE:0:9}; deploying"

# Does this deploy change the snapshot builder? If so we rebuild instead of a bare reload (a
# reload onto a stale-schema snapshot 500s). Detected before the merge from the incoming range.
SCHEMA_CHANGED=
if [ -n "${DEPLOY_BUILD_SERVICE:-}" ] && [ -n "$(git diff --name-only "$LOCAL" "$REMOTE" -- data/build_db.py)" ]; then
  SCHEMA_CHANGED=1
fi

# 2. Fast-forward only (guaranteed by the ancestor check; --ff-only is belt-and-braces).
git merge --ff-only --quiet '@{u}' || { log "fast-forward merge failed (drift) — manual fix needed"; exit 1; }

# 3. Sync deps (frozen). On failure, stop BEFORE the reload.
# shellcheck disable=SC2086
$UV sync $UV_ARGS || { log "uv sync failed; NOT reloading"; exit 1; }

# 4. Rebuild Tailwind CSS only for apps that have it (auto-skips apps with no static/src.css).
if [ -f static/src.css ]; then
  $UV run tailwindcss -i static/src.css -o static/app.css --minify \
    || { log "css build failed; NOT reloading"; exit 1; }
fi

# 5. Apply. If the deploy changed the snapshot builder, dispatch a rebuild — its --reload-service
#    swaps new code + new snapshot together (and runs its own cf-purge). This is gap-free: the
#    running workers keep serving the OLD code + OLD snapshot until that atomic swap, so we do NOT
#    reload here. Otherwise (the common case) just reload onto the new code + purge the edge.
if [ -n "$SCHEMA_CHANGED" ]; then
  log "data/build_db.py changed -> dispatching $DEPLOY_BUILD_SERVICE (rebuilds snapshot, then reloads + purges)"
  $RELOAD_CMD start --no-block "$DEPLOY_BUILD_SERVICE" || { log "could not start $DEPLOY_BUILD_SERVICE"; exit 1; }
  log "deployed ${REMOTE:0:9} (snapshot rebuild dispatched)"
else
  $RELOAD_CMD "$RELOAD" "$APP" || { log "systemctl $RELOAD $APP failed"; exit 1; }
  SERVICE_RESULT=success "$SELF/bin/cf-purge.sh" || true
  log "deployed ${REMOTE:0:9} ($RELOAD)"
fi
