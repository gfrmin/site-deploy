#!/usr/bin/env bash
# Install + enable the auto-deploy timer for one app on this box. Idempotent.
# Run as an admin with sudo:   /srv/site-deploy/bin/install.sh <app>
#
# <app> is the service user == /srv/<app> == /etc/<app>/env. It installs the shared instance
# units, ensures a NOPASSWD `systemctl <verb> <app>` grant for the service user (verb from
# DEPLOY_RELOAD in /etc/<app>/env, default reload), then enables site-deploy@<app>.timer.
# The first tick deploys any backlog.
set -euo pipefail

APP="${1:?usage: install.sh <app>}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"   # /srv/site-deploy

[ -d "/srv/$APP" ]        || { echo "error: no /srv/$APP checkout on this box"; exit 1; }
id "$APP" >/dev/null 2>&1 || { echo "error: no service user '$APP'"; exit 1; }

# Per-app knobs from /etc/<app>/env (bare single values — safe to extract without sourcing the
# systemd-format env file, whose unquoted `KEY=a b c` lines aren't shell-source-safe).
envval() { sudo grep -m1 "^$1=" "/etc/$APP/${2:-env}" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]' || true; }
RELOAD="$(envval DEPLOY_RELOAD)"; RELOAD="${RELOAD:-reload}"
BUILD_SVC="$(envval DEPLOY_BUILD_SERVICE)"
echo "installing auto-deploy for $APP (default verb: systemctl $RELOAD $APP${BUILD_SVC:+; rebuild via $BUILD_SVC})"

# 1. The toolkit itself is ROOT-owned and read-only to everyone else: root runs
#    scripts out of it (deploy/converge.sh via the poller), so the service user
#    must not be able to write it. A box bootstrapped before this was cloned as
#    the service user; the chown is the one-time migration and is idempotent.
#    Its updates come from site-deploy-update.timer (root, tracks the toolkit's
#    tested ref) — see bin/self-update.sh.
sudo chown -R root:root "$HERE"
sudo chmod -R u=rwX,go=rX "$HERE"

# 2. Shared units (installed once per box; harmless to re-copy).
sudo cp "$HERE/systemd/site-deploy@.service" "$HERE/systemd/site-deploy@.timer" \
        "$HERE/systemd/site-deploy-update.service" "$HERE/systemd/site-deploy-update.timer" \
        "$HERE/systemd/site-probe@.service" "$HERE/systemd/site-probe@.timer" \
        "$HERE/systemd/site-checks-armed@.service" "$HERE/systemd/site-checks-armed@.timer" \
        /etc/systemd/system/

# 3. NOPASSWD grants so the service user can reload/restart itself, and (for apps with a snapshot
#    build) dispatch a rebuild when a deploy changes data/build_db.py. Validated before install.
tmp="$(mktemp)"
{
  echo "# Installed by site-deploy/bin/install.sh — auto-deploy grants."
  # Both verbs, whatever DEPLOY_RELOAD says: a deploy that changes uv.lock
  # restarts instead of reloading (a reload cannot re-exec the arbiter), and a
  # grant naming only `reload` would have sudo refuse exactly that deploy.
  printf '%s ALL=(root) NOPASSWD: /usr/bin/systemctl reload %s, /usr/bin/systemctl restart %s\n' "$APP" "$APP" "$APP"
  [ -n "$BUILD_SVC" ] && printf '%s ALL=(root) NOPASSWD: /usr/bin/systemctl start --no-block %s\n' "$APP" "$BUILD_SVC"
} > "$tmp"
sudo visudo -cf "$tmp" >/dev/null
sudo install -m 440 -o root -g root "$tmp" "/etc/sudoers.d/${APP}-deploy"
rm -f "$tmp"

# 4. Enable the timers (first run within ~2 min deploys whatever the box is behind by).
sudo systemctl daemon-reload
sudo systemctl enable --now site-deploy-update.timer
sudo systemctl enable --now "site-deploy@${APP}.timer"

# 5. Monitoring. Both halves are opt-in by env NAME and both nag when absent,
#    because a missing dead-man does not fail — it just never speaks, and
#    nothing distinguishes that from health.
if [ -n "$(envval PROBE_URL)" ] && [ -n "$(envval HEALTHCHECKS_PROBE_URL)" ]; then
  sudo systemctl enable --now "site-probe@${APP}.timer"
  echo "enabled site-probe@${APP}.timer (PROBE_URL -> HEALTHCHECKS_PROBE_URL, every 5 min; size the check 300s/600s)"
else
  sudo systemctl disable --now "site-probe@${APP}.timer" 2>/dev/null || true
  echo "WARNING: PROBE_URL / HEALTHCHECKS_PROBE_URL not set in /etc/$APP/env — THIS APP IS UNPROBED" >&2
fi
if [ -z "$(envval HEALTHCHECKS_DEPLOY_URL)" ]; then
  echo "WARNING: HEALTHCHECKS_DEPLOY_URL not set in /etc/$APP/env — deploys on this box are UNMONITORED (size the check 600s/900s)" >&2
fi
if [ -n "$(envval HEALTHCHECKS_API_KEY ops-env)" ] && [ -n "$(envval HEALTHCHECKS_SWEEP_TAG ops-env)" ]; then
  sudo systemctl enable --now "site-checks-armed@${APP}.timer"
  echo "enabled site-checks-armed@${APP}.timer (sweeps tag $(envval HEALTHCHECKS_SWEEP_TAG ops-env) every 15 min; size its check 900s/900s)"
else
  sudo systemctl disable --now "site-checks-armed@${APP}.timer" 2>/dev/null || true
  echo "note: no HEALTHCHECKS_API_KEY/HEALTHCHECKS_SWEEP_TAG in /etc/$APP/ops-env — alarms are not verified from this box" >&2
fi

# 6. Does the box carry the config the app declares? Names only, never values.
#    A rebuilt box that is missing half its env file serves 200s all day; this
#    is the check that says a rebuilt box equals the one it replaced.
if [ -r "/srv/$APP/deploy/required-env.txt" ]; then
  sudo "$HERE/bin/env-check.sh" "$APP" || echo "WARNING: env-check reported problems above (exit $?)" >&2
else
  echo "note: /srv/$APP/deploy/required-env.txt not found — the app declares no env manifest, so nothing can say whether this box has its config" >&2
fi

echo
echo "enabled site-deploy@${APP}.timer:"
systemctl list-timers "site-deploy@${APP}.timer" --no-pager || true
echo
echo "watch the first deploy:   journalctl -fu site-deploy@${APP}.service"
echo "force one now:            sudo systemctl start site-deploy@${APP}.service"
