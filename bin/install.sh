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

# 3. Does the box carry the config each app declares? Names only, never
#    values. A rebuilt box that is missing half its env file serves 200s all
#    day. Workspace mode (Phase D item 14): loop over every app this site
#    hosts, checking EACH app's OWN /etc/<app>/* and required-env.txt against
#    its own unit (default <site>@<app>.service) rather than the site's.
if grep -q '^\[workspace\]' "/srv/$APP/deploy/site.toml" 2>/dev/null; then
  # shellcheck disable=SC1091
  . "$HERE/lib/workspace.sh"
  APPS_DIR=$(ws_apps_dir "/srv/$APP")
  mapfile -t WS_APPS < <(ws_apps "/srv/$APP" "$APP")
  for a in "${WS_APPS[@]}"; do
    a_dir="$APPS_DIR/$a"
    a_manifest="/srv/$APP/$a_dir/deploy/required-env.txt"
    if [ -r "$a_manifest" ]; then
      a_svc=$(python3 "$HERE/bin/site-config.py" --app-keys "/srv/$APP/$a_dir/deploy/site.toml" 2>/dev/null \
                | sed -n "s/^export DEPLOY_SERVICE=//p" | tail -1 | tr -d "'\"")
      sudo ETC="/etc/$a" MANIFEST="$a_manifest" UNIT="${a_svc:-$APP@$a.service}" \
        "$HERE/bin/env-check.sh" "$a" || echo "WARNING: env-check reported problems above for $a (exit $?)" >&2
    else
      echo "note: $a_manifest not found — $a declares no env manifest, so nothing can say whether this box has its config" >&2
    fi
  done
elif [ -r "/srv/$APP/deploy/required-env.txt" ]; then
  sudo "$HERE/bin/env-check.sh" "$APP" || echo "WARNING: env-check reported problems above (exit $?)" >&2
else
  echo "note: /srv/$APP/deploy/required-env.txt not found — the app declares no env manifest, so nothing can say whether this box has its config" >&2
fi

echo
systemctl list-timers "site-deploy@${APP}.timer" "site-deploy-update.timer" --no-pager || true
echo
echo "watch the first deploy:   journalctl -fu site-deploy@${APP}.service"
echo "force one now:            sudo systemctl start site-deploy@${APP}.service"
