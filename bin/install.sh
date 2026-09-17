#!/usr/bin/env bash
# Install site-deploy for one app on this box. Idempotent.
# Run as an admin with sudo:   /srv/site-deploy/bin/install.sh <app>
#
# <app> is the service user == /srv/<app> == /etc/<app>/env. Everything this
# used to do by hand — copy the units, write the sudoers grant, enable the
# timers — is now bin/host-converge.sh, which the poller re-runs every tick so
# a change in git reaches the box without another visit here. This script is
# the bootstrap: root-own the toolkit, run the first converge, check the env.
set -euo pipefail

APP="${1:?usage: install.sh <app>}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"   # /srv/site-deploy

[ -d "/srv/$APP" ]        || { echo "error: no /srv/$APP checkout on this box"; exit 1; }
id "$APP" >/dev/null 2>&1 || { echo "error: no service user '$APP'"; exit 1; }

# 1. The toolkit itself is ROOT-owned and read-only to everyone else: root runs
#    scripts out of it (host-converge, the app's converge hook), so the service
#    user must not be able to write it. A box bootstrapped before this was
#    cloned as the service user; the chown is the one-time migration and is
#    idempotent. Updates come from site-deploy-update.timer (root, tracks the
#    toolkit's tested ref) — see bin/self-update.sh.
sudo chown -R root:root "$HERE"
sudo chmod -R u=rwX,go=rX "$HERE"

# 2. Converge the host: units, grants, journald, swap, packages, timers. This
#    is also what every deploy tick runs, so "installed" and "converged" are
#    one state. Its warnings about monitoring that is not wired up are the
#    point, not noise.
echo "converging host for $APP"
sudo "$HERE/bin/host-converge.sh" "$APP"

# 3. Does the box carry the config the app declares? Names only, never values.
#    A rebuilt box that is missing half its env file serves 200s all day.
if [ -r "/srv/$APP/deploy/required-env.txt" ]; then
  sudo "$HERE/bin/env-check.sh" "$APP" || echo "WARNING: env-check reported problems above (exit $?)" >&2
else
  echo "note: /srv/$APP/deploy/required-env.txt not found — the app declares no env manifest, so nothing can say whether this box has its config" >&2
fi

echo
systemctl list-timers "site-deploy@${APP}.timer" "site-deploy-update.timer" --no-pager || true
echo
echo "watch the first deploy:   journalctl -fu site-deploy@${APP}.service"
echo "force one now:            sudo systemctl start site-deploy@${APP}.service"
