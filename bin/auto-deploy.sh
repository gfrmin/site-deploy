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
RUNLOG=$(mktemp)
CSS_TMP=""
on_exit() {
  local rc=$?
  [ -n "$CSS_TMP" ] && rm -f "$CSS_TMP"
  if [ "$rc" -ne 0 ]; then
    hc_ping "$HC_DEPLOY" /fail "auto-deploy[$APP]: exit $rc
$(tail -n 60 "$RUNLOG" 2>/dev/null)"
  fi
  rm -f "$RUNLOG"
  exit "$rc"
}
trap on_exit EXIT
log() { echo "auto-deploy[$APP]: $*"; printf '%s\n' "$*" >> "$RUNLOG"; }
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
}

RELOAD="${DEPLOY_RELOAD:-reload}"
UV_ARGS="${DEPLOY_UV_ARGS:---frozen}"
load_site_config
CURL="${CURL:-curl}"
HEALTH_PATH="${DEPLOY_HEALTH_PATH-/health}"
HEALTH_TRIES="${DEPLOY_HEALTH_TRIES:-10}"
CSS_MIN_RATIO="${DEPLOY_CSS_MIN_RATIO:-50}"

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
PENDING_RELOAD="$SRV/.site-deploy-reload-pending"
if [ "$LOCAL" = "$REMOTE" ] && [ ! -f "$PENDING_RELOAD" ]; then
  if [ -n "$REF_FROZEN" ]; then
    # Level with a ref that stopped moving is not "where it should be".
    rm -f "$BEHIND_STAMP" 2>/dev/null || true
    log "DEPLOY GATE FROZEN: $REF_FROZEN"
    hc_ping "$HC_DEPLOY" /fail "auto-deploy[$APP]: GATE FROZEN — $REF_FROZEN"
  else
    report_level "at ${LOCAL:0:9} (origin/$REF)"
  fi
  exit 0                                     # up to date -> silent no-op
fi
# The marker's content is the verb the unfinished deploy needed, if it was not
# the configured one: a deploy that changed uv.lock needs a restart (below), and
# a resumed tick has no diff left to rediscover that from.
RESUME_VERB=""
if [ "$LOCAL" = "$REMOTE" ]; then
  RESUME_VERB=$(tr -d '[:space:]' < "$PENDING_RELOAD")
  log "resuming an unfinished deploy of ${LOCAL:0:9}${RESUME_VERB:+ ($RESUME_VERB)}"
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
    exit 0
  fi
  log "local has diverged from origin (neither is an ancestor of the other) — manual fix needed"
  exit 1
fi

log "${LOCAL:0:9} -> ${REMOTE:0:9} (origin/$REF); deploying"
report_behind "behind origin/$REF (${LOCAL:0:9} vs ${REMOTE:0:9})"
hc_ping "$HC_DEPLOY" /start "auto-deploy[$APP]: deploying ${LOCAL:0:9} -> ${REMOTE:0:9}"

# Does this deploy change the snapshot builder? If so we ALSO dispatch a rebuild after the
# reload below. Detected before the merge from the incoming range.
SCHEMA_CHANGED=
if [ -n "${DEPLOY_BUILD_SERVICE:-}" ] && [ -n "$(git diff --name-only "$LOCAL" "$REMOTE" -- data/build_db.py)" ]; then
  SCHEMA_CHANGED=1
fi

# Same idea for the Cloudflare zone config: dispatch cf-converge@$APP.service
# (root, out of the toolkit, --no-block so a slow Cloudflare API never delays
# this reload) only when this deploy actually touched it -- not every tick,
# since an API round-trip is not something a 2-minute poller should pay for
# when nothing declared changed. cf-drift@.timer is the daily backstop for
# drift from a hand-edit at the dashboard.
CF_CHANGED=
if [ -n "$(git diff --name-only "$LOCAL" "$REMOTE" -- deploy/cloudflare.json)" ]; then
  CF_CHANGED=1
fi

# 2. Fast-forward only (guaranteed by the ancestor check; --ff-only is belt-and-braces).
# A dependency change is a RESTART, not a reload. On SIGHUP gunicorn's arbiter
# re-forks its workers but never re-execs itself: it keeps the interpreter, the
# gunicorn and every module it imported before the first fork. Application code
# IS re-imported after the fork, which is why an ordinary deploy works at all
# and exactly what makes this hard to see — the wheels are installed, the app
# is new, and the server underneath it is whatever was running at boot. Decided
# before the merge (the diff is gone after) and remembered in the marker (a
# resumed tick has no diff at all). -F, not a pattern: `uv.lock` as a regex
# also matches `uvXlock`.
LOCK_CHANGED=""
if git diff --name-only "$LOCAL" "$REMOTE" | grep -qxF uv.lock; then LOCK_CHANGED=1; fi

# Merge the resolved SHA, not the ref name: naming the ref would re-resolve
# it, and a ref that advanced in between would deploy a commit this tick never
# diffed for changed paths.
git merge --ff-only --quiet "$REMOTE" || { log "fast-forward merge failed (drift) — manual fix needed"; exit 1; }
# Cleared once the reload is verified healthy (see step 5). Content = the verb
# this deploy needs, when it is not the configured one.
if [ -n "$LOCK_CHANGED" ]; then echo restart > "$PENDING_RELOAD"; else : > "$PENDING_RELOAD"; fi

# Re-read: this deploy may have just changed it.
load_site_config fatal
if [ -n "$LOCK_CHANGED" ] || [ "$RESUME_VERB" = restart ]; then
  [ "$RELOAD" = restart ] || log "uv.lock changed -> restart, not $RELOAD (a reload cannot re-exec the arbiter)"
  RELOAD=restart
fi

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
  declared=$(sed -n 's/^@source[[:space:]]\{1,\}"\([^"]*\)".*/\1/p' static/src.css)
  n_lines=$(grep -c '^@source' static/src.css || true)
  n_parsed=$(printf '%s' "$declared" | grep -c . || true)
  if [ "$n_lines" != "$n_parsed" ]; then
    log "static/src.css has an @source form this check does not model ($n_lines declared, $n_parsed parsed); NOT building, NOT reloading"
    exit 1
  fi
  while IFS= read -r src; do
    [ -n "$src" ] || continue
    lit=$src
    # shellcheck disable=SC1083
    case $src in *[][*?{]*) lit=${src%%[][*?{]*}; lit=${lit%/*};; esac
    [ -n "$lit" ] || lit=.
    if [ ! -e "static/$lit" ]; then
      log "@source \"$src\" does not resolve on this box (static/$lit is missing) — tailwindcss would exit 0 with an unstyled site; NOT building, NOT reloading"
      exit 1
    fi
  done <<EOF_SOURCES
$declared
EOF_SOURCES

  # TAILWINDCSS_VERSION (site.toml `tailwindcss_version`) pins the compiler:
  # pytailwindcss downloads releases/latest on first use with it unset, so the
  # stylesheet every visitor gets is otherwise compiled by whichever version
  # upstream had published when that box's venv was created.
  [ -n "${TAILWINDCSS_VERSION:-}" ] || log "WARNING tailwindcss_version is not pinned in deploy/site.toml"
  CSS_TMP=$(mktemp "static/.app.css.XXXXXX")   # removed by on_exit if we bail
  # --frozen --no-dev: an unflagged `uv run` re-locks uv.lock inside the
  # checkout on a pyproject/lock mismatch and wedges this very poller on
  # `git merge --ff-only` forever. This is the site a grep for "uv run"
  # misses, because it is spelled $UV.
  $UV run --frozen --no-dev tailwindcss -i static/src.css -o "$CSS_TMP" --minify \
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
  CSS_TMP=""
fi

# 4b. Converge box config from the repo, BEFORE the reload. Opt-in per app via
#     `converge = true` in deploy/site.toml (declared in the app repo, where a pull
#     request reviews it — same reasoning as every other knob in that file).
#
#     This is the half the host layer does not cover: host/provision.sh builds a box
#     ONCE, and nothing afterwards keeps its units in step with the repo. webbsite's
#     2026-09-11 outage is what that costs — Caddy's unit was tracked in no repo at
#     all, so nobody noticed it carried no Restart=, and a single OOM kill became
#     five days of 521s while the app underneath stayed healthy.
#
#     Failure stops the deploy before the reload, exactly like `uv sync` and the CSS
#     canary above: converging half the config and then reloading onto it is the
#     worst of both outcomes.
#
#     TRUST BOUNDARY. A repo-declared systemd unit's ExecStart runs as root, so on a
#     converging box merge access to the app repo IS root on that box. That is the
#     same bargain dataguru-converge makes and it is fine where it is already true,
#     but it must be a deliberate per-app choice, which is why this is opt-in and why
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
  DIRTY=$(git status --porcelain --untracked-files=all -- deploy/)
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
  else
    # Declared but unusable is a misconfiguration, not a reason to deploy blind —
    # the box would keep serving stale units while site.toml claimed otherwise.
    log "site.toml sets converge but deploy/converge.sh is missing or not executable; NOT reloading"
    exit 1
  fi
fi

# 4c. The reload contract. `reload = "reload"` is `systemctl reload <app>`, which
#     is the unit's ExecReload= — and a unit with none makes the verb a silent
#     no-op, so every deploy "succeeds" while the old workers keep serving
#     (the way one box ran for months). And gunicorn's SIGHUP re-imports the app
#     only when preload_app is False; with preload the arbiter keeps the modules
#     it imported at boot and re-forks the old code. Both are checked HERE,
#     after converge (the deploying commit may be the one that adds ExecReload=)
#     and before the verb is sent. The stub in tests answers the show query.
if [ "$RELOAD" = reload ]; then
  if [ -z "$(${SYSCTL_QUERY:-systemctl} show -p ExecReload --value "$APP.service" 2>/dev/null)" ]; then
    log "site.toml says reload = \"reload\" but $APP.service has no ExecReload= — the verb would be a no-op and the old workers would keep serving; declare one, or set reload = \"restart\". NOT reloading"
    exit 1
  fi
  if [ -f gunicorn.conf.py ] && grep -qE '^[[:space:]]*preload_app[[:space:]]*=[[:space:]]*True' gunicorn.conf.py; then
    log "site.toml says reload = \"reload\" but gunicorn.conf.py sets preload_app = True — SIGHUP would re-fork the OLD code; set preload_app = False, or reload = \"restart\". NOT reloading"
    exit 1
  fi
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
if [ -n "$CF_CHANGED" ]; then
  log "deploy/cloudflare.json changed -> dispatching cf-converge@$APP.service"
  $RELOAD_CMD start --no-block "cf-converge@$APP.service" \
    || log "could not start cf-converge@$APP.service (edge config convergence will retry via cf-drift@.timer)"
fi
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
report_level "deployed ${REMOTE:0:9}"
