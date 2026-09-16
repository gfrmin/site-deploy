#!/usr/bin/env bash
# health-probe.sh <app> — active uptime probe, run every 5 min by site-probe@<app>.timer.
#
# This is the OTHER half of the health story from auto-deploy.sh's post-reload
# gate. That gate proves a deploy left the box serving; this notices when a box
# that was serving stops, which no deploy-time check can ever see.
#
# Curls $PROBE_URL (the app's PUBLIC health URL, through Cloudflare — the
# user's vantage point, not the origin's; point it at the DEEP variant where
# the app has one) and reports the outcome to the <app>-probe healthchecks
# check: success pings the check root, anything else pings /fail with the
# evidence. This is the active half a build dead-man cannot provide: that
# notices a build that stopped happening; nothing before this noticed
# *serving* breakage — days of 500s behind a green shallow /health.
#
# Ownership: this script owns BOTH the probe and the ping — one ExecStart, one
# owner. The passive backstop still sits underneath: if this script stops
# running entirely (timer dead, box dead, script bug), the check misses its
# 5-minute cadence and goes down after timeout+grace (300s+600s) with no help
# from this code.
#
# Exit status: 0 when the site answered 200 — even if the healthchecks ping
# then failed; monitoring degradation is journal-only while the site is fine.
# 1 when the probe failed, AFTER the /fail ping is attempted, so
# `systemctl --failed` mirrors reality between runs. Unset URLs are a logged
# no-op, exit 0 — a wholly silent no-op is the shape of a box that ran
# unmonitored for days; install.sh and env-check own the nagging.
set -u
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib/hc.sh"

app=${1:?usage: health-probe.sh <app>}
tag="site-probe: $app"

purl=${PROBE_URL:-}
hurl=${HEALTHCHECKS_PROBE_URL:-}
if [ -z "$purl" ] || [ -z "$hurl" ]; then
  echo "$tag: PROBE_URL/HEALTHCHECKS_PROBE_URL unset; THIS APP IS UNPROBED" >&2
  exit 0
fi

code=$(http_probe "$purl"); rc=$?
if [ "$rc" -eq 0 ] && [ "$code" = "200" ]; then
  hc_ping "$hurl" "" "$tag: ok"
  exit 0
fi
msg="HTTP ${code} (curl exit $rc) from $purl"
hc_ping "$hurl" /fail "$tag: $msg"
echo "$tag: PROBE FAILED — $msg" >&2
exit 1
