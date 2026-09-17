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
#                                              deploy changes a DEPLOY_BUILD_INPUTS path, ALSO
#                                              dispatch a snapshot rebuild after the reload; new
#                                              app code must degrade gracefully on the previous
#                                              snapshot schema)
#   DEPLOY_BUILD_INPUTS=data/build_db.py      (site.toml `build_inputs`; one path prefix per
#                                              line, default data/build_db.py)
#   DEPLOY_SERVICE=$APP.service               (site.toml `service`; the unit reloaded/restarted
#                                              and inspected for the reload contract)
#   CF_ZONE_ID, CF_CACHE_PURGE_TOKEN  (optional; used by bin/cf-purge.sh)
#   DEPLOY_HEALTH_PATH=/health        (probed on 127.0.0.1:$PORT after the reload, before the
#                                      purge; empty disables the gate)
#   DEPLOY_HEALTH_MATCH=<string>      (optional; the body must contain it. A 200 from a
#                                      half-booted worker is not health — see #230)
#   DEPLOY_HEALTH_TRIES=10            (one second apart)
#   DEPLOY_CSS_MIN_RATIO=50           (refuse a rebuilt app.css smaller than this % of the one
#                                      it would replace)
#   TAILWINDCSS_VERSION=4.3.3         (pin the compiler pytailwindcss downloads; unset = latest)
# Override RELOAD_CMD (default `sudo -n /usr/bin/systemctl`) to `echo` for a no-sudo local dry-run.
set -uo pipefail

APP="${APP:?APP env var required (set by site-deploy@.service)}"
SELF="${SITE_DEPLOY_DIR:-/srv/site-deploy}"   # override only for local dry-runs
SRV="${APP_DIR:-/srv/${APP}}"                  # override only for local dry-runs
UV="${UV:-/usr/local/bin/uv}"
RELOAD_CMD="${RELOAD_CMD:-sudo -n /usr/bin/systemctl}"   # override to `echo` for a dry-run

cd "$SRV" || { echo "auto-deploy[$APP]: no checkout at $SRV"; exit 1; }
# shellcheck disable=SC1091
. "$SELF/lib/hc.sh"
# shellcheck disable=SC1091
. "$SELF/lib/workspace.sh"

# --- the deploy dead-man ------------------------------------------------------
# HEALTHCHECKS_DEPLOY_URL (from /etc/<app>/env; unset = no pings, and the poller
# stays silent — install.sh and env-check own the nagging). The subject of the
# ping is deliberately "this box is AT the ref it should be at", not "a tick
# ran": a ran-dead-man is green during the failure it most needs to catch. A
# `git fetch` that fails exits 0 below with one journal line nobody reads, every
# two minutes, forever — which is what a box gets if its deploy key is revoked.
#
# Three edges, none redundant. LEVEL (root ping) fires only when the checkout
# holds the ref. A non-zero exit sends /fail from ONE EXIT trap, so a new `exit`
# added later can never silently stop reporting; hc-unit-result.sh on the unit
# covers the script being killed before its trap. Behind for BEHIND_FAIL_SECONDS
# sends /fail: a real deploy takes one tick, so behind for ~7 of them is stuck,
# not busy. And no ping at all means the timer is gone — that is what the
# check's own timeout+grace (600s+900s) is for.
HC_DEPLOY="${HEALTHCHECKS_DEPLOY_URL:-}"
STATE_DIR="${DEPLOY_STATE_DIR:-$SRV/.site-deploy-state}"
BEHIND_STAMP="$STATE_DIR/behind-since"
BEHIND_FAIL_SECONDS="${BEHIND_FAIL_SECONDS:-900}"
mkdir -p "$STATE_DIR" 2>/dev/null || true
# Per-app queue dirs (Phase D item 14: a workspace site hosts several apps out
# of one checkout; today's single-app site has exactly one entry, $APP, under
# dir "."). pending/<app>: the verb ("reload"|"restart") an unfinished apply
# still owes, cleared once that app's health probe passes. rebuild-pending/<app>:
# an empty flag for a queued-but-not-yet-dispatched snapshot rebuild.
PENDING_DIR="$STATE_DIR/pending"
REBUILD_DIR="$STATE_DIR/rebuild-pending"
RUNLOG=$(mktemp)
CSS_TMP=""
DRAIN_OK=0
on_exit() {
  local rc=$?
  [ -n "$CSS_TMP" ] && rm -f "$CSS_TMP"
  if [ "$rc" -ne 0 ]; then
    hc_ping "$HC_DEPLOY" /fail "auto-deploy[$APP]: exit $rc
$(tail -n 60 "$RUNLOG" 2>/dev/null)"
  elif [ "$DRAIN_OK" = 1 ]; then
    drain_rebuild_queue
  fi
  rm -f "$RUNLOG"
  exit "$rc"
}
trap on_exit EXIT
log() { echo "auto-deploy[$APP]: $*"; printf '%s\n' "$*" >> "$RUNLOG"; }

# One-time migration from the pre-workspace-mode single-file markers to the
# per-app queue directories, so a box with an in-flight retry or a resumed
# deploy is not silently dropped by this refactor.
mkdir -p "$PENDING_DIR" "$REBUILD_DIR" 2>/dev/null || true
if [ -f "$SRV/.site-deploy-reload-pending" ]; then
  legacy_verb=$(tr -d '[:space:]' < "$SRV/.site-deploy-reload-pending")
  printf '%s' "$legacy_verb" > "$PENDING_DIR/$APP"
  rm -f "$SRV/.site-deploy-reload-pending"
  log "migrated legacy .site-deploy-reload-pending -> $PENDING_DIR/$APP${legacy_verb:+ ($legacy_verb)}"
fi
if [ -f "$SRV/.site-deploy-build-pending" ]; then
  : > "$REBUILD_DIR/$APP"
  rm -f "$SRV/.site-deploy-build-pending"
  log "migrated legacy .site-deploy-build-pending -> $REBUILD_DIR/$APP"
fi
# Level: the box holds the ref it should. Clears the stamp so the next stall is
# measured from when it started, not from the last time anything was wrong.
report_level() { rm -f "$BEHIND_STAMP" 2>/dev/null || true; hc_ping "$HC_DEPLOY" "" "auto-deploy[$APP]: $1"; }
# Not level, for whatever reason — behind, or unable to find out. One tick of
# this is an ordinary deploy, so it only alarms once it has persisted.
report_behind() {
  local now since age
  now=$(date +%s)
  since=$(cat "$BEHIND_STAMP" 2>/dev/null || true)
  case "$since" in ''|*[!0-9]*) since=$now; printf '%s\n' "$now" > "$BEHIND_STAMP" 2>/dev/null || true ;; esac
  age=$(( now - since ))
  if [ "$age" -ge "$BEHIND_FAIL_SECONDS" ]; then
    log "DEPLOY STUCK: $1 for ${age}s (threshold ${BEHIND_FAIL_SECONDS}s)"
    hc_ping "$HC_DEPLOY" /fail "auto-deploy[$APP]: STUCK $1 for ${age}s"
  fi
}

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
#
# The pre-merge read is also SCOPED: it evaluates the old file in a subshell and
# takes only the two knobs needed before anything is fetched out of it —
# DEPLOY_BUILD_SERVICE (the queued-rebuild retry) and DEPLOY_REF (which ref to
# fetch at all; a commit changing deploy_ref therefore governs the NEXT deploy,
# necessarily). Evaluating it in this shell exported every old knob, and the
# post-merge read only sets keys the NEW file has — so a knob the deploying
# commit REMOVED (say, health_match) stayed armed from the old copy for exactly
# the deploy that removed it.
load_site_config() {
  [ -f deploy/site.toml ] || return 0
  local rendered
  if rendered=$(python3 "$SELF/bin/site-config.py" deploy/site.toml 2>&1); then
    if [ "${1:-}" = fatal ]; then
      eval "$rendered"
    else
      DEPLOY_BUILD_SERVICE=$( eval "$rendered" 2>/dev/null; printf '%s' "${DEPLOY_BUILD_SERVICE:-}" )
      DEPLOY_REF=$( eval "$rendered" 2>/dev/null; printf '%s' "${DEPLOY_REF:-}" )
      # Scoped like DEPLOY_BUILD_SERVICE, and for the same reason: SCHEMA_CHANGED
      # below is computed from the OLD checkout's diff before anything is
      # fetched, so the path list that decides it has to come from the OLD
      # site.toml too, not from whatever this incoming commit changes it to.
      DEPLOY_BUILD_INPUTS=$( eval "$rendered" 2>/dev/null; printf '%s' "${DEPLOY_BUILD_INPUTS:-}" )
      # Phase D item 14: which apps this SITE hosts is exactly the same kind of
      # fact as DEPLOY_REF -- a decision that must be made from the OLD
      # checkout before anything is fetched, so a commit that turns workspace
      # mode on (or moves apps_dir) governs the NEXT deploy, not its own.
      WORKSPACE_APPS_DIR=$( eval "$rendered" 2>/dev/null; printf '%s' "${WORKSPACE_APPS_DIR:-}" )
      WORKSPACE_SHARED=$( eval "$rendered" 2>/dev/null; printf '%s' "${WORKSPACE_SHARED:-}" )
      return 0
    fi
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
  SERVICE="${DEPLOY_SERVICE:-$APP.service}"
  BUILD_INPUTS="${DEPLOY_BUILD_INPUTS:-data/build_db.py}"
}

RELOAD="${DEPLOY_RELOAD:-reload}"
UV_ARGS="${DEPLOY_UV_ARGS:---frozen}"
SERVICE="${DEPLOY_SERVICE:-$APP.service}"
load_site_config
BUILD_INPUTS="${DEPLOY_BUILD_INPUTS:-data/build_db.py}"
CURL="${CURL:-curl}"
HEALTH_PATH="${DEPLOY_HEALTH_PATH-/health}"
HEALTH_TRIES="${DEPLOY_HEALTH_TRIES:-10}"
CSS_MIN_RATIO="${DEPLOY_CSS_MIN_RATIO:-50}"

# --- workspace mode (Phase D item 14): several apps out of one checkout -----
# Triggered by the SITE's own deploy/site.toml declaring a [workspace] table
# at all (WORKSPACE_APPS_DIR is present iff it does) -- single-app is the
# default and the degenerate case, one app named $APP under dir ".".
WORKSPACE=""
[ -n "${WORKSPACE_APPS_DIR:-}" ] && WORKSPACE=1
APPS_DIR="${WORKSPACE_APPS_DIR:-apps}"
if [ -n "$WORKSPACE" ]; then
  # ws_apps's own diagnostics go straight to stderr (never through log()/
  # RUNLOG -- they are lib/workspace.sh's, not this script's, and already
  # self-prefixed "workspace[$APP]:").
  mapfile -t APPS < <(ws_apps "$SRV" "$APP")
else
  APPS=("$APP")
fi
# dir for app $1: "." in single-app mode (there is only ever one, and it IS
# the checkout root); $APPS_DIR/$1 in workspace mode.
app_dir() { [ -n "$WORKSPACE" ] && printf '%s/%s' "$APPS_DIR" "$1" || printf '.'; }

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
#
# READ THE BODY, NOT THE STATUS CODE — when there is a body to read. With
# health_match set, `-f` is dropped: /health on a snapshot-backed app is an
# operator-alerting endpoint, not a liveness one, and answers 503 on a STALE
# SNAPSHOT while serving every page perfectly. A `-f` probe would call that
# app down, skip the purge, and strand this deploy's templates at the edge for
# a full TTL — the exact bug the purge exists to fix. So: up iff it answered
# HTTP at all AND the body contains the match. Genuinely dead stays down: a
# refused/timed-out connection, a half-booted worker whose body says
# "starting", an nginx/Caddy error page. Without health_match the status code
# is the only datum there is, and `-f` stays.
health_ok() {
  local url=$1 i body fflag=-f
  [ -n "${DEPLOY_HEALTH_MATCH:-}" ] && fflag=""
  for ((i = 1; i <= HEALTH_TRIES; i++)); do
    # shellcheck disable=SC2086
    if body=$($CURL $fflag -sS --max-time 3 "$url" 2>/dev/null); then
      if [ -z "${DEPLOY_HEALTH_MATCH:-}" ] || [[ $body == *"$DEPLOY_HEALTH_MATCH"* ]]; then
        return 0
      fi
    fi
    sleep 1
  done
  return 1
}

# The toolkit no longer updates itself from here. /srv/site-deploy is root-owned
# and site-deploy-update.timer (root) keeps it on the toolkit's tested ref — see
# bin/self-update.sh for why the service user must not own a directory root
# executes from.

# --- the snapshot-rebuild queue -----------------------------------------------
# ONE poller-started build per box per tick (renavon #1561): a workspace box
# can host several apps whose builds are each heavy (memory, I/O), and a
# single commit under a [workspace] `shared`/`build_inputs` prefix is a build
# input for every one of them at once. $BUILD_DISPATCH_FLAG is a FILE, not a
# shell variable, because each app's deploy_app call runs in its own subshell
# in workspace mode (so failure isolation doesn't also isolate this count) —
# a write to it is visible to every later app in the SAME tick regardless.
# Reset once, at the top of the tick, by the caller before the per-app loop.
BUILD_DISPATCH_FLAG="$STATE_DIR/.build-dispatched-this-tick"
rm -f "$BUILD_DISPATCH_FLAG"   # one poller-started build per box, per TICK -- reset before anything below (including an early up-to-date exit) can reach the EXIT trap's drain

# Called when THIS app's OWN diff changed one of ITS build inputs. Busy
# queues a flag rather than blocking: `systemctl start` on an activating
# oneshot is a silent no-op (live miss, crescira 2026-07-13 — the nightly
# was mid-run on pre-push code when a build_db deploy dispatched), so a
# start attempted straight into a busy unit would look like it worked and do
# nothing. A start command that itself fails (not "busy", a real error)
# stays fatal, exactly as a same-tick dispatch always has.
queue_or_dispatch_build() {   # <app>
  local app=$1
  if [ -e "$BUILD_DISPATCH_FLAG" ]; then
    log "$app: another app already dispatched a build on this box this tick (one at a time); queued"
    mkdir -p "$REBUILD_DIR" 2>/dev/null && : > "$REBUILD_DIR/$app"
  elif unit_busy "$DEPLOY_BUILD_SERVICE"; then
    log "$app: $DEPLOY_BUILD_SERVICE is busy; queued (retried every tick until idle)"
    mkdir -p "$REBUILD_DIR" 2>/dev/null && : > "$REBUILD_DIR/$app"
  elif $RELOAD_CMD start --no-block "$DEPLOY_BUILD_SERVICE"; then
    rm -f "$REBUILD_DIR/$app"
    : > "$BUILD_DISPATCH_FLAG"
    log "$app: dispatched $DEPLOY_BUILD_SERVICE (build input changed)"
  else
    log "$app: could not start $DEPLOY_BUILD_SERVICE"
    exit 1
  fi
}

# <app>'s own build_service. Single-app mode: the one already loaded at the
# top level. Workspace mode: sed-extracted from THAT app's own site.toml,
# never eval'd (matching host-converge.sh's convention for a single scalar
# read out of a file the caller does not otherwise trust with a full eval).
app_build_service() {   # <app>
  local app=$1 dir
  if [ -z "$WORKSPACE" ]; then
    printf '%s' "${DEPLOY_BUILD_SERVICE:-}"
    return 0
  fi
  dir=$(app_dir "$app")
  python3 "$SELF/bin/site-config.py" --app-keys "$SRV/$dir/deploy/site.toml" 2>/dev/null \
    | sed -n "s/^export DEPLOY_BUILD_SERVICE=//p" | tail -1 | tr -d "'\""
}

# Drains queued-but-not-dispatched rebuild flags, at most ONE per call —
# same one-build-per-box rule as a same-tick dispatch. Called from the EXIT
# trap at the end of every HEALTHY tick (fetch, ref, sync and converge all
# OK — DRAIN_OK is set near each such exit), including the silent up-to-date
# one, so a flag left by a busy unit is retried without waiting for the next
# build-input change. Never fatal: a failed retry here just logs and waits
# for the next tick, since nothing new is being applied.
drain_rebuild_queue() {
  local f app build_service dispatched=""
  [ -e "$BUILD_DISPATCH_FLAG" ] && dispatched=1   # this tick already used its one dispatch
  for f in "$REBUILD_DIR"/*; do
    [ -e "$f" ] || continue
    [ -z "$dispatched" ] || continue
    app=$(basename "$f")
    build_service=$(app_build_service "$app")
    if [ -z "$build_service" ]; then
      rm -f "$f"
      log "$app: no build_service declared any more; dropping its queued rebuild"
    elif unit_busy "$build_service"; then
      continue
    elif $RELOAD_CMD start --no-block "$build_service"; then
      rm -f "$f"
      dispatched=1
      log "$app: dispatched queued snapshot rebuild"
    else
      log "$app: queued build dispatch failed; will retry next tick"
    fi
  done
}

# 1. Which ref this box deploys. `deploy_ref` in site.toml (default master);
#    for an app whose CI advances a `ci-green` ref only after a green run on
#    master, tracking that ref means the box can only ever fast-forward onto a
#    commit whose whole suite passed. The clone keeps `master` checked out with
#    origin/master as its upstream; only what we compare and merge changes.
#
#    Operator override: a ref name in /etc/<app>/deploy-ref. `master` restores
#    the ungated behaviour for the case this exists to survive — CI itself
#    broken, or a fix that must ship before it can be green. A file rather than
#    a converged setting on purpose: converge would overwrite the override on
#    the next tick. `[ -r ]` first: a failed input redirection prints even under
#    2>/dev/null, and the file is absent in the normal case.
DEPLOY_REF_FILE="${DEPLOY_REF_FILE:-/etc/$APP/deploy-ref}"
REF_OVERRIDE=""
[ -r "$DEPLOY_REF_FILE" ] && REF_OVERRIDE=$(tr -d '[:space:]' < "$DEPLOY_REF_FILE")
REF="${REF_OVERRIDE:-${DEPLOY_REF:-master}}"

# Cheap remote check. A transient fetch failure just retries next tick (exit 0, not failed).
# The explicit wildcard refspec is load-bearing: a box cloned --single-branch
# has remote.origin.fetch narrowed to master, and a bare `git fetch` would then
# never see the tested ref at all. --prune, or a ref deleted on the remote lives
# on locally and passes the existence check below forever.
git fetch --quiet --prune origin '+refs/heads/*:refs/remotes/origin/*' \
  || { log "fetch failed (transient?); will retry next tick"; report_behind "cannot fetch origin"; exit 0; }
LOCAL=$(git rev-parse @)
# No fallback to master if the ref is missing. A gate that opens when it cannot
# find its own lock is not a gate: an accidentally deleted ref, or a repo where
# CI has never run, would silently restore ungated deploys. Refusing keeps the
# last known-good tree serving — but it can strand a box indefinitely, so it is
# loud on EVERY tick (and exit 1 sends the dead-man /fail).
if ! REMOTE=$(git rev-parse --verify --quiet "refs/remotes/origin/$REF"); then
  log "REFUSING TO DEPLOY: origin/$REF does not exist, so there is no tested commit to deploy." \
      "The box keeps serving ${LOCAL:0:9}. Fix CI, or write a ref that exists (e.g. master) to" \
      "$DEPLOY_REF_FILE to bypass the gate."
  exit 1
fi
# How far behind master the tracked ref is. A red CI stops the ref advancing,
# which is the point — but the visible symptom is "my merge never deployed", and
# without this the poller reports a silent no-op while master runs away from it.
# One line per tick is not enough on its own (nobody reads it) — so if the ref
# has not MOVED for REF_FROZEN_SECONDS while master is ahead, the dead-man is
# told the box is NOT where it should be. Keyed on the ref's SHA: a busy day of
# green merges moves the ref, restamps, and never trips this.
REF_FROZEN=""
REF_FROZEN_STAMP="$STATE_DIR/ref-frozen-since"
REF_FROZEN_SECONDS="${REF_FROZEN_SECONDS:-3600}"
if [ "$REF" != master ] && MASTER=$(git rev-parse --verify --quiet refs/remotes/origin/master) \
   && [ "$MASTER" != "$REMOTE" ] && [ "$(git rev-list --count "$REMOTE..$MASTER" 2>/dev/null || echo 0)" != 0 ]; then
  behind=$(git rev-list --count "$REMOTE..$MASTER")
  log "WARNING origin/$REF is $behind commit(s) behind origin/master (${REMOTE:0:9} vs ${MASTER:0:9}) — those commits are NOT deployed. CI is red, still running, or never ran for them."
  now=$(date +%s); frozen_sha=""; frozen_since=""
  [ -r "$REF_FROZEN_STAMP" ] && read -r frozen_sha frozen_since < "$REF_FROZEN_STAMP"
  case "$frozen_since" in ''|*[!0-9]*) frozen_sha="" ;; esac
  if [ "$frozen_sha" != "$REMOTE" ]; then
    { printf '%s %s\n' "$REMOTE" "$now" > "$REF_FROZEN_STAMP"; } 2>/dev/null || true
  elif [ $(( now - frozen_since )) -ge "$REF_FROZEN_SECONDS" ]; then
    REF_FROZEN="origin/$REF has not moved for $(( now - frozen_since ))s while origin/master is $behind commit(s) ahead — CI is red or not running, so this box is level with an untested gap"
  fi
else
  rm -f "$REF_FROZEN_STAMP" 2>/dev/null || true
fi
# A deploy is not finished when the merge lands — it is finished when the new
# code is reloaded and answering. Anything that fails in between (uv sync, the
# CSS build, the reload, the health probe) leaves the checkout already merged,
# so the next tick would see "up to date", exit 0, and quietly turn the failed
# unit green while the box still runs the old workers. This marker makes the
# unfinished half retry instead.
# any_pending: true iff at least one hosted app has an outstanding marker. A
# single-app site has exactly one entry in $APPS, so this is a strict
# generalisation of "the one marker exists" -- unchanged behaviour there.
any_pending() {
  local a
  for a in "${APPS[@]}"; do [ -f "$PENDING_DIR/$a" ] && return 0; done
  return 1
}
if [ "$LOCAL" = "$REMOTE" ] && ! any_pending; then
  if [ -n "$REF_FROZEN" ]; then
    # Level with a ref that stopped moving is not "where it should be".
    rm -f "$BEHIND_STAMP" 2>/dev/null || true
    log "DEPLOY GATE FROZEN: $REF_FROZEN"
    hc_ping "$HC_DEPLOY" /fail "auto-deploy[$APP]: GATE FROZEN — $REF_FROZEN"
  else
    report_level "at ${LOCAL:0:9} (origin/$REF)"
  fi
  DRAIN_OK=1                                 # fetch/ref/sync all fine this tick
  exit 0                                     # up to date -> silent no-op
fi
if [ "$LOCAL" = "$REMOTE" ]; then
  log "resuming an unfinished deploy of ${LOCAL:0:9}"
fi

# Recover from a uv.lock that something re-locked in place. Every `uv run` in
# this script carries --frozen, but that cannot stop an operator pasting an
# unflagged one from a runbook, and a box that is ALREADY dirty is not helped
# by prevention: the ff-only merge below refuses every two minutes forever,
# with a journal line nobody reads as the only symptom. Discarding is
# unambiguously right — uv.lock is committed, so a working copy that differs
# from HEAD was written by a machine, and we are about to install from it.
# The named file, never `git checkout .`: an operator's in-place hotfix must
# not vanish with no log line.
if [ -n "$(git status --porcelain -- uv.lock)" ]; then
  log "uv.lock is MODIFIED in the checkout — something ran uv without --frozen; discarding it"
  git checkout -- uv.lock || log "could not restore uv.lock; the sync below will install from it as-is"
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
    report_level "ahead of origin at ${LOCAL:0:9}"
    DRAIN_OK=1
    exit 0
  fi
  log "local has diverged from origin (neither is an ancestor of the other) — manual fix needed"
  exit 1
fi

log "${LOCAL:0:9} -> ${REMOTE:0:9} (origin/$REF); deploying"
report_behind "behind origin/$REF (${LOCAL:0:9} vs ${REMOTE:0:9})"
hc_ping "$HC_DEPLOY" /start "auto-deploy[$APP]: deploying ${LOCAL:0:9} -> ${REMOTE:0:9}"

# The whole incoming diff, computed once before the merge (the diff is gone
# after it) -- both the site-wide LOCK_CHANGED decision below and each hosted
# app's in-scope/build-input decisions (in deploy_app, since those are
# per-app knobs) read it from here rather than re-diffing per app.
CHANGED=$(git diff --name-only "$LOCAL" "$REMOTE")

# A dependency change is a RESTART, not a reload. On SIGHUP gunicorn's arbiter
# re-forks its workers but never re-execs itself: it keeps the interpreter, the
# gunicorn and every module it imported before the first fork. Application code
# IS re-imported after the fork, which is why an ordinary deploy works at all
# and exactly what makes this hard to see — the wheels are installed, the app
# is new, and the server underneath it is whatever was running at boot. Decided
# before the merge (the diff is gone after); the marker (never downgraded, see
# lib/workspace.sh's queue-contract note) is what a resumed tick reads back,
# since a same-commit resume has no diff to rediscover it from. -F, not a
# pattern: `uv.lock` as a regex also matches `uvXlock`.
LOCK_CHANGED=""
printf '%s\n' "$CHANGED" | grep -qxF uv.lock && LOCK_CHANGED=1

# Merge the resolved SHA, not the ref name: naming the ref would re-resolve
# it, and a ref that advanced in between would deploy a commit this tick never
# diffed for changed paths.
git merge --ff-only --quiet "$REMOTE" || { log "fast-forward merge failed (drift) — manual fix needed"; exit 1; }

# Which hosted apps does THIS tick's diff put in scope, and what marker verb
# do they need? Single-app: every commit governs the one app, as always --
# there is nothing else "in scope" could mean with one app. Workspace: an app
# is in scope when the diff touches its own directory, the site's top-level
# deploy/ (fleet.toml, site-wide policy), the shared venv files (uv.lock,
# pyproject.toml), or a declared [workspace] shared prefix.
#
# A marker already carrying "restart" is NEVER downgraded back to "reload" by
# a later tick whose OWN diff didn't touch uv.lock -- the obligation from an
# earlier lock change survives until it is actually applied, however many
# ticks that takes (a CSS failure, say, retrying the same app).
mkdir -p "$PENDING_DIR" 2>/dev/null || true
for app in "${APPS[@]}"; do
  in_scope=""
  if [ -n "$WORKSPACE" ]; then
    dir=$(app_dir "$app")
    pattern="^(${dir}/|uv\.lock$|pyproject\.toml$|deploy/"
    while IFS= read -r sp; do [ -n "$sp" ] && pattern="$pattern|^${sp}"; done <<< "$WORKSPACE_SHARED"
    pattern="$pattern)"
    printf '%s\n' "$CHANGED" | grep -qE "$pattern" && in_scope=1
  else
    in_scope=1
  fi
  [ -n "$in_scope" ] || continue
  if [ -n "$LOCK_CHANGED" ]; then
    echo restart > "$PENDING_DIR/$app"
  elif [ ! -f "$PENDING_DIR/$app" ] || [ "$(cat "$PENDING_DIR/$app" 2>/dev/null)" != restart ]; then
    : > "$PENDING_DIR/$app"
  fi
done

# Re-read the SITE's own config: this deploy may have just changed it. Only
# UV_ARGS/TAILWINDCSS_VERSION/DEPLOY_CONVERGE (and, in single-app mode, the
# per-app RELOAD/SERVICE/etc) come from this call -- a workspace app's OWN
# knobs are read fresh from ITS OWN site.toml inside deploy_app, per app.
# The lock-changed-forces-restart decision also moved there (deploy_app reads
# the marker it is about to apply), since that is now a per-app fact.
load_site_config fatal

# 3. Sync deps (frozen). Workspace mode scopes the sync to the hosted apps via
#    `--package`, exactly the "one lock resolves every app, --package narrows
#    which of them land in THIS box's venv" split renavon's #409 established.
#    Three rules, each because the alternative is worse than the fat venv:
#      1. a name that is not a real workspace member (no matching
#         `name = "<app>"` in <dir>/pyproject.toml) emits NO --package flags at
#         all -- `uv sync --package nosuchapp` exits before touching the venv,
#         which is a wedged deploy for a typo in fleet.toml/the override file.
#      2. an empty hosted-app list emits NO flags either -- collapsing to some
#         other scope invents a decision this file cannot support.
#      3. a scoped sync that fails for any OTHER reason retries unscoped once
#         before giving up, so scoping itself can never be what stops a deploy.
#    On failure, stop BEFORE the reload -- same rule as always.
SYNC_SCOPE=()
if [ -n "$WORKSPACE" ]; then
  scope_ok=1
  if [ "${#APPS[@]}" -eq 0 ]; then
    log "no apps hosted here — syncing the whole workspace"
    scope_ok=""
  else
    for app in "${APPS[@]}"; do
      dir=$(app_dir "$app")
      if ! grep -qxF "name = \"$app\"" "$dir/pyproject.toml" 2>/dev/null; then
        log "WARNING '$app' is not a workspace member ($dir/pyproject.toml does not declare it) — syncing the whole workspace rather than scoping it"
        scope_ok=""
        break
      fi
    done
  fi
  if [ -n "$scope_ok" ]; then
    for app in "${APPS[@]}"; do SYNC_SCOPE+=(--package "$app"); done
  fi
fi
# shellcheck disable=SC2086
if ! $UV sync $UV_ARGS ${SYNC_SCOPE[@]+"${SYNC_SCOPE[@]}"}; then
  if [ "${#SYNC_SCOPE[@]}" -gt 0 ]; then
    log "scoped uv sync failed (${SYNC_SCOPE[*]}); retrying unscoped"
    # shellcheck disable=SC2086
    $UV sync $UV_ARGS || { log "uv sync failed; NOT reloading"; exit 1; }
  else
    log "uv sync failed; NOT reloading"; exit 1
  fi
fi

# 4b. Converge the SITE's own box config from the repo, BEFORE any app's
#     reload. Opt-in via `converge = true` in the site's OWN deploy/site.toml
#     (declared in the repo, where a pull request reviews it — same reasoning
#     as every other knob in that file). One converge DECISION per site
#     (`converge` is a SITE_ONLY_KEY, never read from a workspace app's own
#     site.toml) applied here once, then again per hosted app inside
#     deploy_app below.
#
#     This is the half the host layer does not cover: host/provision.sh builds a box
#     ONCE, and nothing afterwards keeps its units in step with the repo. webbsite's
#     2026-09-11 outage is what that costs — Caddy's unit was tracked in no repo at
#     all, so nobody noticed it carried no Restart=, and a single OOM kill became
#     five days of 521s while the app underneath stayed healthy.
#
#     Failure stops the deploy before any reload, exactly like `uv sync` above:
#     converging half the config and then reloading onto it is the worst of both
#     outcomes.
#
#     TRUST BOUNDARY. A repo-declared systemd unit's ExecStart runs as root, so on a
#     converging box merge access to the repo IS root on that box. That is the
#     same bargain dataguru-converge makes and it is fine where it is already true,
#     but it must be a deliberate per-site choice, which is why this is opt-in and why
#     it needs its own sudoers grant rather than riding on the systemctl one.
#     "True" is first because site-config.py renders values with Python's str(), so a
#     TOML `converge = true` arrives as the capitalised form; the others accept a
#     hand-set /etc/<app>/env override.
if [ "${DEPLOY_CONVERGE:-}" = "True" ] || [ "${DEPLOY_CONVERGE:-}" = "true" ] || [ "${DEPLOY_CONVERGE:-}" = "1" ]; then
  # Root runs deploy/converge.sh out of a checkout the SERVICE USER can write.
  # "Merge access is root" is the bargain converge makes on purpose; "an RCE in
  # the app is root two minutes later" is not, and without this check it would
  # be: edit deploy/converge.sh in place, wait for the next tick. So root only
  # ever executes a deploy/ tree that is byte-identical to the commit just
  # merged — tracked files unmodified AND nothing untracked, because a converge
  # engine that installs deploy/systemd/* would otherwise install a unit nobody
  # committed. Refusing leaves the old code serving, like every other pre-reload
  # failure; the marker makes the next tick retry once the tree is clean.
  #
  # Workspace mode widens the pathspec to every HOSTED app's own deploy/ tree
  # too (each app's converge, below, runs root out of ITS directory), not
  # only the site's top-level one.
  dirty_paths=(deploy/)
  if [ -n "$WORKSPACE" ]; then
    for a in "${APPS[@]}"; do dirty_paths+=("$(app_dir "$a")/deploy/"); done
  fi
  DIRTY=$(git status --porcelain --untracked-files=all -- "${dirty_paths[@]}")
  if [ -n "$DIRTY" ]; then
    log "REFUSING to converge: deploy/ in $SRV differs from the commit (edited on the box?); NOT reloading"
    echo "$DIRTY" | sed "s/^/auto-deploy[$APP]:   /"
    exit 1
  fi
  # The box below the app first: the toolkit's own units, the grants, the
  # journald cap, swap, packages, the Caddy restart policy. Root, out of the
  # root-owned toolkit — never out of the app checkout. A failure here stops
  # the deploy like any other pre-reload failure.
  ${HOST_CONVERGE_CMD:-sudo -n "$SELF/bin/host-converge.sh"} "$APP" \
    || { log "host-converge failed; NOT reloading"; exit 1; }
  if [ -x deploy/converge.sh ]; then
    ${CONVERGE_CMD:-sudo -n} "$SRV/deploy/converge.sh" \
      || { log "deploy/converge.sh failed; NOT reloading"; exit 1; }
  elif [ -e deploy/converge.sh ]; then
    # Present but not executable is a misconfiguration (a forgotten chmod
    # +x), not "this app has none" — the box would keep serving stale units
    # while site.toml claimed otherwise.
    log "site.toml sets converge but deploy/converge.sh is not executable; NOT reloading"
    exit 1
  else
    # No app-owned script at all: fall back to the toolkit's own
    # [converge]-table engine (bin/converge.sh), the shape webbsite's and
    # renavon's hand-written converge.sh scripts had already converged on
    # independently — install, validate, reload-with-rollback, prune. An app
    # with converge=true but NEITHER a script NOR a [converge] table is
    # still a real misconfiguration; bin/converge.sh's own "nothing
    # declared" exit 0 surfaces it in the log without treating it as a crash.
    ${CONVERGE_ENGINE_CMD:-sudo -n "$SELF/bin/converge.sh"} "$APP" \
      || { log "bin/converge.sh failed; NOT reloading"; exit 1; }
  fi
fi

# --- deploy_app: one hosted app's apply (CSS, per-app converge, reload, ----
#     health, purge, build dispatch). Single-app mode calls this ONCE,
#     directly (its `return 1`/`exit 1` therefore ends the whole script,
#     exactly as this code always has); workspace mode calls it once per
#     hosted app inside a subshell (its failures end only that subshell, so
#     one app's bad deploy cannot strand the others -- but the OVERALL tick
#     still ends non-zero, see the loop below).
deploy_app() {   # <app> <dir>
  local app=$1 dir=$2
  cd "$dir" || { log "$app: no directory at $dir, skipping"; return 1; }

  if [ -n "$WORKSPACE" ]; then
    # Per-app config, read from THIS app's own site.toml (the merge already
    # landed, so this is the NEW copy -- a commit changing an app's own
    # config governs its own deploy, the same rule the site-level fatal
    # re-read already applies to the site's config). --app-keys: the
    # site-only knobs make no sense in an app's own file and are warned
    # about, not silently read.
    local rendered
    if ! rendered=$(python3 "$SELF/bin/site-config.py" --app-keys deploy/site.toml 2>&1); then
      log "$app: $rendered"
      log "$app: refusing to deploy blind on an unreadable deploy/site.toml"
      return 1
    fi
    eval "$rendered"
    RELOAD="${DEPLOY_RELOAD:-reload}"
    SERVICE="${DEPLOY_SERVICE:-$APP@$app.service}"
    HEALTH_PATH="${DEPLOY_HEALTH_PATH-/health}"
    HEALTH_TRIES="${DEPLOY_HEALTH_TRIES:-10}"
    CSS_MIN_RATIO="${DEPLOY_CSS_MIN_RATIO:-50}"
    BUILD_INPUTS="${DEPLOY_BUILD_INPUTS:-data/build_db.py}"
    # DEPLOY_CONVERGE is deliberately NOT re-set here: --app-keys never
    # renders it (it is a SITE_ONLY_KEY), so whatever the site-level
    # load_site_config already put there survives untouched -- one
    # converge decision, applied per app below.
  fi

  # The verb this app's marker actually owes. `restart` is never downgraded
  # (see the write loop above): a lock change forces it regardless of what
  # the app itself declares, because SIGHUP cannot re-exec the arbiter onto
  # a newly synced dependency.
  if [ "$(cat "$PENDING_DIR/$app" 2>/dev/null)" = restart ]; then
    [ "$RELOAD" = restart ] || log "$app: uv.lock changed -> restart, not $RELOAD (a reload cannot re-exec the arbiter)"
    RELOAD=restart
  fi

  # Does this deploy change $app's OWN build inputs? Detected from the
  # site-wide $CHANGED via git pathspecs relative to $app's directory --
  # single-app mode's dir is ".", so these are repo-root paths exactly as
  # before; a directory prefix here fails OPEN into one extra rebuild (the
  # safe direction), an allow-list of exact files fails CLOSED into a
  # silently stale snapshot (renavon gfrmin/dataguru#344).
  # `git -C "$SRV" diff` explicitly, not a bare `git diff`: pathspecs are
  # CWD-relative, and we are already `cd`'d into $app's own directory above
  # -- a bare `git diff ... -- apps/foo/data/build_db.py` from inside
  # apps/foo/ resolves to apps/foo/apps/foo/data/build_db.py and silently
  # matches nothing. -C pins the repo root so these repo-root-relative
  # paths mean what they say regardless of CWD.
  local schema_changed="" build_paths=() bp cf_rel
  while IFS= read -r bp; do [ -n "$bp" ] && build_paths+=("$([ "$dir" = . ] && printf '%s' "$bp" || printf '%s/%s' "$dir" "$bp")"); done <<< "$BUILD_INPUTS"
  if [ -n "${DEPLOY_BUILD_SERVICE:-}" ] && [ "${#build_paths[@]}" -gt 0 ] \
     && [ -n "$(git -C "$SRV" diff --name-only "$LOCAL" "$REMOTE" -- "${build_paths[@]}")" ]; then
    schema_changed=1
  fi
  # Same idea for the Cloudflare zone config: dispatch cf-converge@<app>
  # (root, out of the toolkit, --no-block so a slow Cloudflare API never
  # delays this reload) only when THIS deploy actually touched it.
  cf_rel=$([ "$dir" = . ] && printf 'deploy/cloudflare.json' || printf '%s/deploy/cloudflare.json' "$dir")
  local cf_changed=""
  [ -n "$(git -C "$SRV" diff --name-only "$LOCAL" "$REMOTE" -- "$cf_rel")" ] && cf_changed=1

  # 4. Rebuild Tailwind CSS only for apps that have it (auto-skips apps with no static/src.css).
  # `tailwindcss -o` truncates and rewrites in place, and static/app.css is served
  # `immutable`. A run that exits 0 having emitted a near-empty file — a bad
  # content glob, a missing config — therefore ships an unstyled site AND gets a
  # cache purge to spread it (crhkguru shipped 34,958 B -> 6,695 B with exit 0).
  # So: build to a temp file, compare it against what it would replace, and only
  # then rename. The rename is atomic, so no request is ever served a half-written
  # stylesheet.
  if [ -f static/src.css ]; then
    # Exit status is necessary but NOT sufficient. tailwindcss exits 0 with a
    # drastically smaller stylesheet when an @source path does not resolve — a
    # mistyped path is byte-identical to declaring no sources at all — and the
    # size canary below has uneven reach: on an app whose src.css is mostly
    # hand-written CSS the loss is a few percent, well inside the ratio. So every
    # declared `@source "…"` is checked against the filesystem first, at its
    # literal prefix (the part a typo lands in). `^@source` anchors past prose
    # that discusses @source inside CSS comments. `@source not "…"` and
    # `@source inline("…")` mean something else and are REPORTED rather than
    # silently skipped: two parsers of one syntax will drift, and the count
    # comparison is what stops drift becoming silence. Zero @source lines is
    # deliberately fine — the size floor covers that.
    local declared n_lines n_parsed src lit CSS_TMP NEW_BYTES OLD_BYTES
    declared=$(sed -n 's/^@source[[:space:]]\{1,\}"\([^"]*\)".*/\1/p' static/src.css)
    n_lines=$(grep -c '^@source' static/src.css || true)
    n_parsed=$(printf '%s' "$declared" | grep -c . || true)
    if [ "$n_lines" != "$n_parsed" ]; then
      log "$app: static/src.css has an @source form this check does not model ($n_lines declared, $n_parsed parsed); NOT building, NOT reloading"
      return 1
    fi
    while IFS= read -r src; do
      [ -n "$src" ] || continue
      lit=$src
      # shellcheck disable=SC1083
      case $src in *[][*?{]*) lit=${src%%[][*?{]*}; lit=${lit%/*};; esac
      [ -n "$lit" ] || lit=.
      if [ ! -e "static/$lit" ]; then
        log "$app: @source \"$src\" does not resolve on this box (static/$lit is missing) — tailwindcss would exit 0 with an unstyled site; NOT building, NOT reloading"
        return 1
      fi
    done <<EOF_SOURCES
$declared
EOF_SOURCES

    # TAILWINDCSS_VERSION (site.toml `tailwindcss_version`, a site-level knob)
    # pins the compiler: pytailwindcss downloads releases/latest on first use
    # with it unset, so the stylesheet every visitor gets is otherwise
    # compiled by whichever version upstream had published when that box's
    # venv was created.
    [ -n "${TAILWINDCSS_VERSION:-}" ] || log "$app: WARNING tailwindcss_version is not pinned in deploy/site.toml"
    CSS_TMP=$(mktemp "static/.app.css.XXXXXX")   # removed by on_exit if we bail
    # --frozen --no-dev: an unflagged `uv run` re-locks uv.lock inside the
    # checkout on a pyproject/lock mismatch and wedges this very poller on
    # `git merge --ff-only` forever. This is the site a grep for "uv run"
    # misses, because it is spelled $UV.
    if ! $UV run --frozen --no-dev tailwindcss -i static/src.css -o "$CSS_TMP" --minify; then
      log "$app: css build failed; NOT reloading"; rm -f "$CSS_TMP"; return 1
    fi
    NEW_BYTES=$(wc -c < "$CSS_TMP")
    if [ "$NEW_BYTES" -lt 1024 ]; then
      log "$app: css build produced only ${NEW_BYTES}B (floor 1024B) — refusing to install it; NOT reloading"
      rm -f "$CSS_TMP"; return 1
    fi
    if [ -f static/app.css ]; then
      OLD_BYTES=$(wc -c < static/app.css)
      if [ "$OLD_BYTES" -gt 0 ] && [ $((NEW_BYTES * 100 / OLD_BYTES)) -lt "$CSS_MIN_RATIO" ]; then
        log "$app: css collapsed ${OLD_BYTES}B -> ${NEW_BYTES}B (under ${CSS_MIN_RATIO}%) — refusing to install it; NOT reloading"
        rm -f "$CSS_TMP"; return 1
      fi
    fi
    mv -f "$CSS_TMP" static/app.css
  fi

  # 4b'. Per-app converge: the SAME three-way rule as the site-level one
  # above, scoped to THIS app's own deploy/ tree (already checked clean as
  # part of the site-wide dirty-tree refusal, before any converge ran this
  # tick). Workspace mode only -- single-app mode's one converge call above
  # already covers its one app, and calling it again here would run
  # deploy/converge.sh (or bin/converge.sh $APP) a second time for nothing.
  if [ -n "$WORKSPACE" ] && { [ "${DEPLOY_CONVERGE:-}" = "True" ] || [ "${DEPLOY_CONVERGE:-}" = "true" ] || [ "${DEPLOY_CONVERGE:-}" = "1" ]; }; then
    if [ -x deploy/converge.sh ]; then
      ${CONVERGE_CMD:-sudo -n} "$SRV/$dir/deploy/converge.sh" \
        || { log "$app: deploy/converge.sh failed; NOT reloading"; return 1; }
    elif [ -e deploy/converge.sh ]; then
      log "$app: converge is on but deploy/converge.sh is not executable; NOT reloading"
      return 1
    else
      ${CONVERGE_ENGINE_CMD:-sudo -n "$SELF/bin/converge.sh"} "$app" \
        || { log "$app: bin/converge.sh failed; NOT reloading"; return 1; }
    fi
  fi

  # 4c. The reload contract. `reload = "reload"` is `systemctl reload <service>`,
  #     which is the unit's ExecReload= — and a unit with none makes the verb a
  #     silent no-op, so every deploy "succeeds" while the old workers keep
  #     serving (the way one box ran for months). And gunicorn's SIGHUP
  #     re-imports the app only when preload_app is False; with preload the
  #     arbiter keeps the modules it imported at boot and re-forks the old code.
  #     Both are checked HERE, after converge (the deploying commit may be the
  #     one that adds ExecReload=) and before the verb is sent.
  if [ "$RELOAD" = reload ]; then
    if [ -z "$(${SYSCTL_QUERY:-systemctl} show -p ExecReload --value "$SERVICE" 2>/dev/null)" ]; then
      log "$app: site.toml says reload = \"reload\" but $SERVICE has no ExecReload= — the verb would be a no-op and the old workers would keep serving; declare one, or set reload = \"restart\". NOT reloading"
      return 1
    fi
    if [ -f gunicorn.conf.py ] && grep -qE '^[[:space:]]*preload_app[[:space:]]*=[[:space:]]*True' gunicorn.conf.py; then
      log "$app: site.toml says reload = \"reload\" but gunicorn.conf.py sets preload_app = True — SIGHUP would re-fork the OLD code; set preload_app = False, or reload = \"restart\". NOT reloading"
      return 1
    fi
  fi

  # 5. Apply: reload onto the new code IMMEDIATELY, even when a snapshot rebuild is coming. Jinja
  #    reads templates from disk, so from the moment the merge landed the old workers were already
  #    rendering the NEW templates — deferring the reload leaves old Python under new templates,
  #    which 500s on any template that needs new Python (live incident, crescira 2026-07-12: new
  #    template kwarg + old templates_config). The app-side contract making this safe: new code
  #    must degrade gracefully on the previous snapshot schema (feature-detect tables/columns).
  $RELOAD_CMD "$RELOAD" "$SERVICE" || { log "$app: systemctl $RELOAD $SERVICE failed"; return 1; }

  # Purging before the origin serves the new code just refills the edge from
  # stale — or worse, from a 500. So the purge is gated on the app actually
  # answering, and an unhealthy app fails the unit with the edge left intact,
  # which is the strictly better failure: visitors keep getting the cached old
  # site instead of a cold broken one.
  if [ -n "$HEALTH_PATH" ] && [ -n "${PORT:-}" ]; then
    local HEALTH_URL="http://127.0.0.1:${PORT}${HEALTH_PATH}"
    if ! health_ok "$HEALTH_URL"; then
      log "$app: unhealthy after $RELOAD: $HEALTH_URL did not answer${DEPLOY_HEALTH_MATCH:+ with '$DEPLOY_HEALTH_MATCH'} in ${HEALTH_TRIES}s — NOT purging"
      return 1
    fi
    log "$app: health ok ($HEALTH_URL)"
  else
    log "$app: WARNING health gate disabled (no PORT/DEPLOY_HEALTH_PATH) — purging unverified"
  fi

  rm -f "$PENDING_DIR/$app"
  SERVICE_RESULT=success "$SELF/bin/cf-purge.sh" || true
  if [ -n "$cf_changed" ]; then
    log "$app: deploy/cloudflare.json changed -> dispatching cf-converge@$app.service"
    $RELOAD_CMD start --no-block "cf-converge@$app.service" \
      || log "$app: could not start cf-converge@$app.service (edge config convergence will retry via cf-drift@.timer)"
  fi
  # If the deploy changed a build input, also rebuild — its --reload-service
  # swaps the new snapshot in atomically and runs its own cf-purge when done.
  # Routed through the same helper the EXIT-trap drain uses, so "busy" and
  # "dispatch failed" are handled identically whether the trigger was this
  # tick's own diff or a flag left over from an earlier one.
  if [ -n "$schema_changed" ]; then
    queue_or_dispatch_build "$app"
  fi
  log "$app: deployed ${REMOTE:0:9} ($RELOAD)"
}

# One call per app carrying a marker -- fresh from this tick's diff, or
# resumed from an earlier tick that could not finish. Single-app mode calls
# deploy_app DIRECTLY (its exit ends the whole script, as always); workspace
# mode wraps each call in a subshell so one app's failure cannot strand the
# others, but still counts it: "partial success is failure" -- the tick's
# own exit code, and therefore the deploy dead-man, must reflect that the
# box is not fully at the ref it should be at, even though every OTHER app
# deployed cleanly in the same tick.
FAILED_APPS=()
for app in "${APPS[@]}"; do
  [ -f "$PENDING_DIR/$app" ] || continue
  dir=$(app_dir "$app")
  if [ -n "$WORKSPACE" ]; then
    ( cd "$SRV" && deploy_app "$app" "$dir" ) || FAILED_APPS+=("$app")
  else
    # Single-app mode: deploy_app's `return 1` must end THIS script, exactly
    # as every inline `exit 1` here always has -- there is no subshell to
    # contain it, and no other app to keep going for.
    deploy_app "$app" "$dir" || exit 1
  fi
done

if [ "${#FAILED_APPS[@]}" -gt 0 ]; then
  log "NOT fully deployed: ${FAILED_APPS[*]} still failing (each reason is above)"
  exit 1
fi
report_level "deployed ${REMOTE:0:9}"
DRAIN_OK=1   # healthy end of a deploy tick: the EXIT trap may now drain the rebuild queue
