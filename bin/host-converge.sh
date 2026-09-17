#!/usr/bin/env bash
# host-converge.sh <app> — converge the BOX below the app to what the toolkit
# and the app repo declare. Root. Idempotent. Silent when nothing changed.
#
# host/provision.sh builds a box ONCE. Nothing afterwards kept its systemd
# units, sudoers, journald cap, swap or package set in step with what git says
# they are, so a box was a function of the repo only on the day it was built.
# `converge = true` closed that gap for the APP's declarations (its units, its
# Caddyfile); this closes it for everything underneath — the toolkit's own
# units, the grants the poller needs, the things that make a small box survive
# a bad night. On a fleet of cattle a rebuilt box has to come out identical to
# the one it replaced, and the only way to know is to converge every tick and
# see nothing change.
#
# Runs from the poller (as root via a scoped NOPASSWD grant) right before the
# app's deploy/converge.sh when site.toml sets converge = true, and once from
# install.sh. Prints only what it CHANGED, plus the standing nags for monitoring
# that was never wired up (a box nobody hooked to an alarm must say so, or it
# looks like a box that is fine).
#
# Soft-fail accounting: nearly every step soft-fails and continues, because the
# steps are independent and a box that converged five of six things is better
# than one that stopped at the first. What must not happen is the run then
# exiting 0 — so each failure is counted and the run ends non-zero with one
# greppable HOST-CONVERGE FAILED line, which the poller turns into "NOT reloading".
#
# What stays manual, and why: /etc/<app>/* (secrets), /etc/caddy/certs/*
# (private keys), the app's own deploy/ (that is the app's converge.sh).
#
# TRUST: this installs files as root out of /srv/site-deploy — which is
# root-owned and updated only onto the toolkit's tested ref (bin/self-update.sh)
# — never out of the app checkout the service user can write.
set -uo pipefail

APP=${1:?usage: host-converge.sh <app>}
# $ROOT prefixes every FILE path and is EMPTY in production, so the constants
# are literally /srv/site-deploy, /etc/... and /swapfile; tests point them at a
# sandbox. It is NOT a sandbox on its own: systemctl, apt-get, sysctl, swapon
# and visudo are invoked unprefixed and act on the real host — the test
# supplies stubs for all of them on PATH, and that combination is the sandbox.
ROOT="${HOST_ROOT:-}"
SELF="$ROOT/srv/site-deploy"
SRV="$ROOT/srv/$APP"
ETC="$ROOT/etc"
APP_ETC="$ETC/$APP"
SWAPFILE="$ROOT/swapfile"

say() { echo "host-converge[$APP]: $*"; }
# The toolkit is the SOURCE of everything below. Without it this would be a
# root process installing nothing, writing a sudoers file, and enabling units
# that do not exist — which is what an unstubbed test run did on a dev box.
[ -d "$SELF/systemd" ] && [ -d "$SELF/host" ] \
  || { say "no toolkit checkout at $SELF (nothing to converge from); refusing"; exit 1; }
[ -d "$SRV" ] || { say "no app checkout at $SRV; refusing"; exit 1; }
failures=0
note_failure() { failures=$((failures + 1)); say "$*"; }

# Install $1 at $2 only if it differs. Returns 0 when it wrote something.
# A missing SOURCE is a counted failure, not a silent "updated": the first
# unsandboxed run of this script had no toolkit checkout to read from, said
# "updated" for every file, and restarted journald on the strength of it.
sync_file() {
  local src=$1 dst=$2 mode=${3:-0644}
  [ -f "$src" ] || { note_failure "cannot install $dst: source $src is missing"; return 1; }
  if [ -f "$dst" ] && cmp -s "$src" "$dst"; then return 1; fi
  install -d -m0755 "$(dirname "$dst")" && install -m"$mode" "$src" "$dst" \
    || { note_failure "could not install $dst"; return 1; }
  say "updated $dst"
  return 0
}
# A value from an env file WITHOUT sourcing it (it holds secrets). Last wins.
envval() { [ -r "$2" ] && sed -n "s/^$1=//p" "$2" | tail -1 | tr -d '"'"'"'[:space:]'; }

units_changed=0
changed_timers=()

# --- 1. the toolkit's own units --------------------------------------------------
# install.sh copied them once; a change to any of them (a pinned ref in an
# Environment=, a new ExecStopPost) reached a box only if a human recopied it.
for f in "$SELF"/systemd/*.service "$SELF"/systemd/*.timer; do
  [ -e "$f" ] || continue
  u=$(basename "$f")
  if sync_file "$f" "$ETC/systemd/system/$u"; then
    units_changed=1
    case $u in *.timer) changed_timers+=("$u") ;; esac
  fi
done

# --- 2. scoped NOPASSWD sudo for the service user -------------------------------
# Written here rather than only at install so that adding a grant is a deploy,
# not a visit. Both reload and restart: a deploy that changes uv.lock restarts.
# Validated before it replaces the live file — a malformed sudoers would leave
# the box unable to escalate at all.
build_svc=$(envval DEPLOY_BUILD_SERVICE "$APP_ETC/env")
if [ -f "$SRV/deploy/site.toml" ]; then
  toml_build=$(python3 "$SELF/bin/site-config.py" "$SRV/deploy/site.toml" 2>/dev/null \
                 | sed -n "s/^export DEPLOY_BUILD_SERVICE=//p" | tr -d "'\"")
  [ -n "$toml_build" ] && build_svc=$toml_build
fi
tmp_sudo=$(mktemp)
{
  echo "# Managed by site-deploy host-converge — edits on the box are overwritten each tick."
  echo "$APP ALL=(root) NOPASSWD: /usr/bin/systemctl reload $APP, /usr/bin/systemctl restart $APP"
  [ -n "$build_svc" ] && echo "$APP ALL=(root) NOPASSWD: /usr/bin/systemctl start --no-block $build_svc"
  echo "$APP ALL=(root) NOPASSWD: /srv/site-deploy/bin/host-converge.sh $APP"
  echo "$APP ALL=(root) NOPASSWD: /srv/$APP/deploy/converge.sh"
} > "$tmp_sudo"
if visudo -cf "$tmp_sudo" >/dev/null 2>&1; then
  sync_file "$tmp_sudo" "$ETC/sudoers.d/$APP-deploy" 0440 || true
else
  note_failure "REFUSED to install sudoers for $APP: failed validation"
fi
rm -f "$tmp_sudo"

# --- 3. journald cap ---------------------------------------------------------------
# Unbounded, the journal on a small box grows to gigabytes and the next disk
# alarm is the first anyone hears of it.
if sync_file "$SELF/host/journald.conf" "$ETC/systemd/journald.conf.d/site-deploy.conf"; then
  systemctl restart systemd-journald || note_failure "journald: restart failed after config change"
fi

# --- 4. needrestart: never restart a running batch unit ---------------------------
# unattended-upgrades runs needrestart from its apt hook, and needrestart
# restarts every unit still mapping an upgraded library — a Type=oneshot build
# or refresh mid-run included (SIGTERM, status 143, then from scratch). The
# app's long-lived unit stays ELIGIBLE on purpose: restarting a server onto a
# patched libc is the whole point of needrestart, and its stop is graceful.
tmp_nr=$(mktemp)
sed "s/__APP__/$APP/g" "$SELF/host/needrestart.conf.tpl" > "$tmp_nr"
sync_file "$tmp_nr" "$ETC/needrestart/conf.d/site-deploy.conf" || true
rm -f "$tmp_nr"

# --- 5. unattended security upgrades ------------------------------------------------
sync_file "$SELF/host/apt-auto-upgrades.conf" "$ETC/apt/apt.conf.d/20auto-upgrades" || true

# --- 6. packages: the fleet baseline plus what the app declares ---------------------
# Installed on diff only: `apt-get install` of an installed set is not free, and
# a tick that touches apt every two minutes is a tick nobody wants to read.
PKG_FILES=("$SELF/host/packages.txt")
[ -f "$SRV/deploy/packages.txt" ] && PKG_FILES+=("$SRV/deploy/packages.txt")
missing=()
while read -r pkg; do
  [ -n "$pkg" ] || continue
  dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed" || missing+=("$pkg")
done < <(grep -hvE '^\s*#|^\s*$' "${PKG_FILES[@]}" | sort -u)
if [ ${#missing[@]} -gt 0 ]; then
  say "installing missing packages: ${missing[*]}"
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${missing[@]}" >/dev/null; then
    note_failure "packages: apt-get install failed for: ${missing[*]}"
  fi
fi

# --- 7. swap + swappiness -------------------------------------------------------------
# Droplets ship with none. A box with no swap had the kernel OOM-kill a build
# mid-promote AND a live web worker two minutes later. Swap does not make an
# oversized job fit; it gives the kernel somewhere to put cold pages instead of
# reaching for the OOM killer on a transient spike.
if [ -z "$(swapon --show=NAME --noheadings 2>/dev/null)" ]; then
  if [ ! -e "$SWAPFILE" ]; then
    fallocate -l 4G "$SWAPFILE" || dd if=/dev/zero of="$SWAPFILE" bs=1M count=4096
    chmod 0600 "$SWAPFILE"
    mkswap "$SWAPFILE" >/dev/null
    say "created 4G $SWAPFILE"
  fi
  # Non-fatal: it CAN fail on an existing but unformatted swapfile (a killed
  # fallocate). Losing swap is worth a warning; losing the converge is not.
  if swapon "$SWAPFILE"; then say "enabled swap on $SWAPFILE"
  else note_failure "swap: $SWAPFILE exists but swapon failed; no swap on this box"; fi
fi
# Gated on the file existing, not on the block above having run: a box that
# already had swap under another name must not get an fstab entry for a
# /swapfile nobody created, or the next boot's `swapon -a` fails on it.
# The newline guard is not cosmetic: an fstab whose last line has no trailing
# newline takes the append GLUED onto that line, corrupting whatever mount it
# described (a data disk, on the box this was first seen on).
if [ -e "$SWAPFILE" ] && ! grep -qxF '/swapfile none swap sw 0 0' "$ETC/fstab" 2>/dev/null; then
  [ ! -s "$ETC/fstab" ] || [ -z "$(tail -c1 "$ETC/fstab")" ] || echo >> "$ETC/fstab"
  echo '/swapfile none swap sw 0 0' >> "$ETC/fstab" && say "added /swapfile to fstab"
fi
# swappiness=10, not 60: a serving box's hot set is page cache, which is cheap
# to re-read, so evicting the app's anonymous memory to hold more of it is
# precisely backwards.
if sync_file "$SELF/host/sysctl-swappiness.conf" "$ETC/sysctl.d/60-site-swappiness.conf"; then
  sysctl -q -p "$ETC/sysctl.d/60-site-swappiness.conf" || note_failure "sysctl: could not apply swappiness"
fi

# --- 8. Caddy: restart policy + memory cap, wherever Caddy is installed ------------------
# The stock unit carries no Restart=, so one OOM kill of the proxy was five days
# of 521s while the app underneath answered every health check. The drop-in
# makes an overload kill LOCAL and recoverable: a cgroup ceiling means the
# kernel kills only Caddy, Restart=always brings it back, and the app never
# enters the OOM victim lottery. Knobs from /etc/site-deploy/host.env
# (CADDY_MEMORY_HIGH / CADDY_MEMORY_MAX) for a box of a different size.
if systemctl cat caddy.service >/dev/null 2>&1; then
  mh=$(envval CADDY_MEMORY_HIGH "$ETC/site-deploy/host.env"); mh=${mh:-1G}
  mm=$(envval CADDY_MEMORY_MAX "$ETC/site-deploy/host.env");  mm=${mm:-1536M}
  tmp_caddy=$(mktemp)
  sed "s/__MEMORY_HIGH__/$mh/; s/__MEMORY_MAX__/$mm/" "$SELF/host/caddy/override.conf" > "$tmp_caddy"
  sync_file "$tmp_caddy" "$ETC/systemd/system/caddy.service.d/site-deploy.conf" && units_changed=1
  rm -f "$tmp_caddy"
fi

# --- 9. timers: enabled iff their configuration exists -------------------------------------
# `enable` only takes effect at the next boot; `enable --now` arms it on this
# tick. Safe for every timer here: none is Persistent=true, so arming never
# fires a catch-up run.
#
# Two kinds of timer, two policies for one an operator STOPPED without
# disabling. An ALARM timer (probe, sweep) is re-armed: there is no sanctioned
# stopped state for an alarm — a stopped timer is a silently dead alarm, and
# the way to stand a probe down is to blank its env pair (the script logs
# UNPROBED) and pause the check. A WORK timer (the toolkit updater, the deploy
# poller) is left stopped: `systemctl stop site-deploy-update.timer` is how an
# operator pins the toolkit through an incident, and a deploy tick must not
# undo that behind their back. Both are enabled if they never were.
arm() {   # arm <timer> <why> [rearm]
  local t=$1 why=$2 rearm=${3:-}
  if ! systemctl is-enabled --quiet "$t" 2>/dev/null; then
    systemctl enable --quiet --now "$t" && say "enabled $t ($why)"
  elif [ -n "$rearm" ] && ! systemctl is-active --quiet "$t" 2>/dev/null; then
    systemctl start "$t" && say "re-armed $t (was enabled but stopped; to stand an alarm down, blank its env pair instead)"
  fi
}
disarm() {
  local t=$1 why=$2
  if systemctl is-enabled --quiet "$t" 2>/dev/null; then
    systemctl disable --quiet --now "$t" && say "disabled $t ($why)"
  fi
}
arm site-deploy-update.timer "keeps the toolkit on its tested ref"
arm "site-deploy@$APP.timer" "the deploy poller"

if [ -n "$(envval PROBE_URL "$APP_ETC/env")" ] && [ -n "$(envval HEALTHCHECKS_PROBE_URL "$APP_ETC/env")" ]; then
  arm "site-probe@$APP.timer" "PROBE_URL + HEALTHCHECKS_PROBE_URL set" rearm
else
  disarm "site-probe@$APP.timer" "PROBE_URL/HEALTHCHECKS_PROBE_URL unset"
  say "PROBE_URL/HEALTHCHECKS_PROBE_URL not set in $APP_ETC/env — THIS APP IS UNPROBED"
fi
if [ -n "$(envval HEALTHCHECKS_API_KEY "$APP_ETC/ops-env")" ] && [ -n "$(envval HEALTHCHECKS_SWEEP_TAG "$APP_ETC/ops-env")" ]; then
  arm "site-checks-armed@$APP.timer" "ops-env carries an API key and a sweep tag" rearm
else
  disarm "site-checks-armed@$APP.timer" "ops-env gone or incomplete"
fi
[ -n "$(envval HEALTHCHECKS_DEPLOY_URL "$APP_ETC/env")" ] \
  || say "HEALTHCHECKS_DEPLOY_URL not set in $APP_ETC/env — deploys on this box are UNMONITORED"

# --- 10. apply ------------------------------------------------------------------------------
if [ "$units_changed" = 1 ]; then
  systemctl daemon-reload && say "systemd daemon-reloaded"
  # A timer whose unit changed keeps its old schedule until restarted. Gated on
  # is-active as well as is-enabled: a timer an operator stopped stays stopped
  # rather than being resurrected by an unrelated unit change. (None of these
  # is Persistent=true, so a restart is a pure reschedule — but the gate costs
  # nothing and the rule is worth keeping uniform.)
  for t in "${changed_timers[@]}"; do
    case $t in *@.timer) t="${t%@.timer}@$APP.timer" ;; esac
    if systemctl is-enabled --quiet "$t" 2>/dev/null && systemctl is-active --quiet "$t" 2>/dev/null; then
      systemctl restart "$t" && say "restarted $t (unit changed)"
    fi
  done
fi

if [ "$failures" -gt 0 ]; then
  say "HOST-CONVERGE FAILED — $failures step(s) did not converge (each is named above)"
  exit 1
fi
exit 0
