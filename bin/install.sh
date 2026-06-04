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

# Reload verb from /etc/<app>/env (a single bare value — safe to extract without sourcing the
# systemd-format env file, whose unquoted `KEY=a b c` lines aren't shell-source-safe).
RELOAD="$(sudo grep -m1 '^DEPLOY_RELOAD=' "/etc/$APP/env" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]' || true)"
RELOAD="${RELOAD:-reload}"
echo "installing auto-deploy for $APP (verb: systemctl $RELOAD $APP)"

# 1. Shared instance units (installed once per box; harmless to re-copy).
sudo cp "$HERE/systemd/site-deploy@.service" "$HERE/systemd/site-deploy@.timer" /etc/systemd/system/

# 2. NOPASSWD grant so the service user can reload/restart itself. Validated before install.
tmp="$(mktemp)"
printf '# Installed by site-deploy/bin/install.sh — auto-deploy reload grant.\n%s ALL=(root) NOPASSWD: /usr/bin/systemctl %s %s\n' \
  "$APP" "$RELOAD" "$APP" > "$tmp"
sudo visudo -cf "$tmp" >/dev/null
sudo install -m 440 -o root -g root "$tmp" "/etc/sudoers.d/${APP}-deploy"
rm -f "$tmp"

# 3. Enable the timer (first run within ~2 min deploys whatever the box is behind by).
sudo systemctl daemon-reload
sudo systemctl enable --now "site-deploy@${APP}.timer"

echo
echo "enabled site-deploy@${APP}.timer:"
systemctl list-timers "site-deploy@${APP}.timer" --no-pager || true
echo
echo "watch the first deploy:   journalctl -fu site-deploy@${APP}.service"
echo "force one now:            sudo systemctl start site-deploy@${APP}.service"
