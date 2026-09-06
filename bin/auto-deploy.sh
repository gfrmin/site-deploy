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
#                                              deploy changes data/build_db.py, ALSO dispatch a
#                                              snapshot rebuild after the reload; new app code must
#                                              degrade gracefully on the previous snapshot schema)
#   CF_ZONE_ID, CF_CACHE_PURGE_TOKEN  (optional; used by bin/cf-purge.sh)
#   DEPLOY_HEALTH_PATH=/health        (probed on 127.0.0.1:$PORT after the reload, before the
#                                      purge; empty disables the gate)
#   DEPLOY_HEALTH_MATCH=<string>      (optional; the body must contain it. A 200 from a
#                                      half-booted worker is not health — see #230)
#   DEPLOY_HEALTH_TRIES=10            (one second apart)
#   DEPLOY_CSS_MIN_RATIO=50           (refuse a rebuilt app.css smaller than this % of the one
#                                      it would replace)
# Override RELOAD_CMD (default `sudo -n /usr/bin/systemctl`) to `echo` for a no-sudo local dry-run.
set -uo pipefail

APP="${APP:?APP env var required (set by site-deploy@.service)}"
SELF="${SITE_DEPLOY_DIR:-/srv/site-deploy}"   # override only for local dry-runs
SRV="${APP_DIR:-/srv/${APP}}"                  # override only for local dry-runs
UV="${UV:-/usr/local/bin/uv}"
RELOAD_CMD="${RELOAD_CMD:-sudo -n /usr/bin/systemctl}"   # override to `echo` for a dry-run

cd "$SRV" || { echo "auto-deploy[$APP]: no checkout at $SRV"; exit 1; }

# Per-app config, from the app's own repo. An app with no deploy/site.toml keeps
# its knobs in /etc/<app>/env exactly as before — this is additive.
#
# Called TWICE, and that is not redundancy. The first call arms the knobs needed
# before anything is fetched (the queued-rebuild retry needs DEPLOY_BUILD_SERVICE).
# The second runs after the merge, so a commit that changes site.toml governs its
# OWN deploy rather than the next one — otherwise every config change ships one
# tick late, which is exactly the kind of off-by-one that gets debugged as a
# mystery rather than read off the file.
# $1 = "fatal" to abort on an unreadable file.
#
# The pre-merge read must NOT be fatal, or a broken site.toml deadlocks the box:
# the file that breaks the deploy is the same file the repair commit fixes, and
# the tick would die reading the old copy before it ever fetched the new one.
# After the merge it IS fatal — by then it is the config being deployed, and
# falling back to the environment would mean deploying with knobs nobody wrote.
load_site_config() {
  [ -f deploy/site.toml ] || return 0
  local rendered
  if rendered=$(python3 "$SELF/bin/site-config.py" deploy/site.toml 2>&1); then
    eval "$rendered"
  else
    echo "auto-deploy[$APP]: $rendered"
    if [ "${1:-}" = fatal ]; then
      echo "auto-deploy[$APP]: refusing to deploy blind on an unreadable deploy/site.toml"
      exit 1
    fi
    echo "auto-deploy[$APP]: continuing anyway (pre-merge) so a fix can land"
    return 0
  fi
  RELOAD="${DEPLOY_RELOAD:-reload}"
  UV_ARGS="${DEPLOY_UV_ARGS:---frozen}"
  HEALTH_PATH="${DEPLOY_HEALTH_PATH-/health}"
  HEALTH_TRIES="${DEPLOY_HEALTH_TRIES:-10}"
  CSS_MIN_RATIO="${DEPLOY_CSS_MIN_RATIO:-50}"
}

RELOAD="${DEPLOY_RELOAD:-reload}"
UV_ARGS="${DEPLOY_UV_ARGS:---frozen}"
load_site_config
CURL="${CURL:-curl}"
HEALTH_PATH="${DEPLOY_HEALTH_PATH-/health}"
HEALTH_TRIES="${DEPLOY_HEALTH_TRIES:-10}"
CSS_MIN_RATIO="${DEPLOY_CSS_MIN_RATIO:-50}"
log() { echo "auto-deploy[$APP]: $*"; }

# `systemctl start` on a oneshot that is still running is a SILENT no-op, so
# anything that dispatches a build has to know whether it is busy. `deactivating`
# counts: a oneshot runs its ExecStopPost (reload-service, cf-purge) in that
# state, and it was missing here — the gap that made the dispatch look like it
# had worked while doing nothing.
unit_busy() {
  local state
  state=$(systemctl is-active "$1" 2>/dev/null || true)
  [ "$state" = "activating" ] || [ "$state" = "active" ] || [ "$state" = "deactivating" ]
}

# "systemctl accepted the verb" is not "the site is up". A reload returns as soon
# as SIGHUP is delivered, so without this the next line purges the edge and
# refills it from an origin that may be throwing ImportError.
health_ok() {
  local url=$1 i body
  for ((i = 1; i <= HEALTH_TRIES; i++)); do
    if body=$($CURL -fsS --max-time 3 "$url" 2>/dev/null); then
      if [ -z "${DEPLOY_HEALTH_MATCH:-}" ] || [[ $body == *"$DEPLOY_HEALTH_MATCH"* ]]; then
        return 0
      fi
    fi
    sleep 1
  done
  return 1
}

# 0. Self-update the toolkit (best-effort + silent; a toolkit change lands on the NEXT tick).
git -C "$SELF" pull --ff-only --quiet 2>/dev/null || true

# 0b. Retry a queued snapshot rebuild. `systemctl start` on an activating oneshot is a silent
#     no-op (live miss, crescira 2026-07-13: the nightly was mid-run — on pre-push code — when a
#     build_db deploy dispatched), so step 5 queues a flag instead and every tick retries here
#     until the unit is idle. Runs BEFORE the up-to-date early-exit on purpose.
PENDING_BUILD="$SRV/.site-deploy-build-pending"
if [ -n "${DEPLOY_BUILD_SERVICE:-}" ] && [ -f "$PENDING_BUILD" ]; then
  if ! unit_busy "$DEPLOY_BUILD_SERVICE"; then
    log "queued snapshot rebuild -> starting $DEPLOY_BUILD_SERVICE"
    $RELOAD_CMD start --no-block "$DEPLOY_BUILD_SERVICE" && rm -f "$PENDING_BUILD"
  fi
fi

# 1. Cheap remote check. A transient fetch failure just retries next tick (exit 0, not failed).
git fetch --quiet origin || { log "fetch failed (transient?); will retry next tick"; exit 0; }
LOCAL=$(git rev-parse @)
REMOTE=$(git rev-parse '@{u}')
# A deploy is not finished when the merge lands — it is finished when the new
# code is reloaded and answering. Anything that fails in between (uv sync, the
# CSS build, the reload, the health probe) leaves the checkout already merged,
# so the next tick would see "up to date", exit 0, and quietly turn the failed
# unit green while the box still runs the old workers. This marker makes the
# unfinished half retry instead.
PENDING_RELOAD="$SRV/.site-deploy-reload-pending"
if [ "$LOCAL" = "$REMOTE" ] && [ ! -f "$PENDING_RELOAD" ]; then
  exit 0                                     # up to date -> silent no-op
fi
if [ "$LOCAL" = "$REMOTE" ]; then
  log "resuming an unfinished deploy of ${LOCAL:0:9}"
fi

# Only deploy when upstream is STRICTLY ahead (local is an ancestor of remote). If local is ahead
# of or diverged from origin, bail loudly rather than reload-looping every tick on a drifted box.
if ! git merge-base --is-ancestor "$LOCAL" "$REMOTE"; then
  # Local ahead of origin is a state that heals itself the moment the commit is
  # pushed (or dropped), and it is what a hand-run build or a local hotfix looks
  # like. Treating it as fatal made a drifted box emit a FAILED unit every two
  # minutes, which trains everyone to ignore `systemctl --failed`. Genuine
  # divergence — neither commit an ancestor of the other — stays fatal, because
  # nothing but a human can resolve it.
  if git merge-base --is-ancestor "$REMOTE" "$LOCAL"; then
    log "local is ahead of origin by $(git rev-list --count "$REMOTE".."$LOCAL") commit(s) — nothing to deploy"
    exit 0
  fi
  log "local has diverged from origin (neither is an ancestor of the other) — manual fix needed"
  exit 1
fi

log "${LOCAL:0:9} -> ${REMOTE:0:9}; deploying"

# Does this deploy change the snapshot builder? If so we ALSO dispatch a rebuild after the
# reload below. Detected before the merge from the incoming range.
SCHEMA_CHANGED=
if [ -n "${DEPLOY_BUILD_SERVICE:-}" ] && [ -n "$(git diff --name-only "$LOCAL" "$REMOTE" -- data/build_db.py)" ]; then
  SCHEMA_CHANGED=1
fi

# 2. Fast-forward only (guaranteed by the ancestor check; --ff-only is belt-and-braces).
git merge --ff-only --quiet '@{u}' || { log "fast-forward merge failed (drift) — manual fix needed"; exit 1; }
touch "$PENDING_RELOAD"   # cleared once the reload is verified healthy (see step 5)

# Re-read: this deploy may have just changed it.
load_site_config fatal

# 3. Sync deps (frozen). On failure, stop BEFORE the reload.
# shellcheck disable=SC2086
$UV sync $UV_ARGS || { log "uv sync failed; NOT reloading"; exit 1; }

# 4. Rebuild Tailwind CSS only for apps that have it (auto-skips apps with no static/src.css).
# `tailwindcss -o` truncates and rewrites in place, and static/app.css is served
# `immutable`. A run that exits 0 having emitted a near-empty file — a bad
# content glob, a missing config — therefore ships an unstyled site AND gets a
# cache purge to spread it (crhkguru shipped 34,958 B -> 6,695 B with exit 0).
# So: build to a temp file, compare it against what it would replace, and only
# then rename. The rename is atomic, so no request is ever served a half-written
# stylesheet.
if [ -f static/src.css ]; then
  CSS_TMP=$(mktemp "static/.app.css.XXXXXX")
  # shellcheck disable=SC2064
  trap "rm -f '$CSS_TMP'" EXIT
  $UV run tailwindcss -i static/src.css -o "$CSS_TMP" --minify \
    || { log "css build failed; NOT reloading"; exit 1; }
  NEW_BYTES=$(wc -c < "$CSS_TMP")
  if [ "$NEW_BYTES" -lt 1024 ]; then
    log "css build produced only ${NEW_BYTES}B (floor 1024B) — refusing to install it; NOT reloading"
    exit 1
  fi
  if [ -f static/app.css ]; then
    OLD_BYTES=$(wc -c < static/app.css)
    if [ "$OLD_BYTES" -gt 0 ] && [ $((NEW_BYTES * 100 / OLD_BYTES)) -lt "$CSS_MIN_RATIO" ]; then
      log "css collapsed ${OLD_BYTES}B -> ${NEW_BYTES}B (under ${CSS_MIN_RATIO}%) — refusing to install it; NOT reloading"
      exit 1
    fi
  fi
  mv -f "$CSS_TMP" static/app.css
  trap - EXIT
fi

# 5. Apply: reload onto the new code IMMEDIATELY, even when a snapshot rebuild is coming. Jinja
#    reads templates from disk, so from the moment the merge landed the old workers were already
#    rendering the NEW templates — deferring the reload leaves old Python under new templates,
#    which 500s on any template that needs new Python (live incident, crescira 2026-07-12: new
#    template kwarg + old templates_config). The app-side contract making this safe: new code
#    must degrade gracefully on the previous snapshot schema (feature-detect tables/columns).
$RELOAD_CMD "$RELOAD" "$APP" || { log "systemctl $RELOAD $APP failed"; exit 1; }

# Purging before the origin serves the new code just refills the edge from
# stale — or worse, from a 500. So the purge is gated on the app actually
# answering, and an unhealthy app fails the unit with the edge left intact,
# which is the strictly better failure: visitors keep getting the cached old
# site instead of a cold broken one.
if [ -n "$HEALTH_PATH" ] && [ -n "${PORT:-}" ]; then
  HEALTH_URL="http://127.0.0.1:${PORT}${HEALTH_PATH}"
  if ! health_ok "$HEALTH_URL"; then
    log "unhealthy after $RELOAD: $HEALTH_URL did not answer${DEPLOY_HEALTH_MATCH:+ with '$DEPLOY_HEALTH_MATCH'} in ${HEALTH_TRIES}s — NOT purging"
    exit 1
  fi
  log "health ok ($HEALTH_URL)"
else
  log "WARNING health gate disabled (no PORT/DEPLOY_HEALTH_PATH) — purging unverified"
fi

rm -f "$PENDING_RELOAD"
SERVICE_RESULT=success "$SELF/bin/cf-purge.sh" || true
# If the deploy changed the snapshot builder, also rebuild — its --reload-service swaps the new
# snapshot in atomically and runs its own cf-purge when done.
if [ -n "$SCHEMA_CHANGED" ]; then
  if unit_busy "$DEPLOY_BUILD_SERVICE"; then
    # A build is mid-run on the code it started with; `start` now would be a silent no-op.
    log "data/build_db.py changed but $DEPLOY_BUILD_SERVICE is busy -> queueing rebuild (retried each tick)"
    touch "$PENDING_BUILD"
    log "deployed ${REMOTE:0:9} ($RELOAD + snapshot rebuild queued)"
  else
    log "data/build_db.py changed -> dispatching $DEPLOY_BUILD_SERVICE (rebuilds snapshot, then reloads + purges again)"
    $RELOAD_CMD start --no-block "$DEPLOY_BUILD_SERVICE" || { log "could not start $DEPLOY_BUILD_SERVICE"; exit 1; }
    log "deployed ${REMOTE:0:9} ($RELOAD + snapshot rebuild dispatched)"
  fi
else
  log "deployed ${REMOTE:0:9} ($RELOAD)"
fi
