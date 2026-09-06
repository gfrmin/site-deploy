#!/usr/bin/env bash
# health-probe.sh <app> — active uptime probe.
#
# Promoted from dataguru's deploy/host/bin/dataguru-probe.sh, which was already
# fully portable: it takes the app name as a label and everything else from
# PROBE_URL / HEALTHCHECKS_PROBE_URL. Unchanged but for the name.
#
# This is the OTHER half of the health story from auto-deploy.sh's post-reload
# gate. That gate proves a deploy left the box serving; this notices when a box
# that was serving stops, which no deploy-time check can ever see.
#
# Curls $PROBE_URL (the app's PUBLIC health URL, through Cloudflare — the
# user's vantage point, not the origin's) and reports the outcome to the
# <app>-probe healthchecks.io check: success pings the check root, anything
# else pings /fail with the evidence. This is the active half the build
# dead-man switches (#245) cannot provide: they notice a build that stopped
# happening; nothing before this noticed *serving* breakage — #267's failure
# class is crescira's 2026-07 incidents, days of 500s behind a green shallow
# /health (which is why its ?deep=1 variant exists, and why PROBE_URL points
# at the deep variant where an app has one).
#
# Ownership: this script owns BOTH the probe and the ping — one ExecStart,
# one owner, no SERVICE_RESULT gymnastics. (Contrast the publish unit, where
# two ExecStart= lines force the UNIT to own the pings, #246.) The passive
# backstop still sits underneath: if this script stops running entirely
# (timer dead, box dead, script bug), the check misses its 5-minute cadence
# and goes down after timeout+grace (300s+600s) with no help from this code.
#
# Exit status: 0 when the site answered 200 — even if the healthchecks ping
# then failed; monitoring degradation is journal-only while the site is fine.
# 1 when the probe failed, AFTER the /fail ping is attempted, so
# `systemctl --failed` mirrors reality between runs (the next successful
# probe's start resets it). Unset URLs are a logged no-op, exit 0: the
# manifest grades both names required@fresh, so env-check owns the nagging.
set -u

app=${1:?usage: health-probe.sh <app>}
tag="site-probe: $app"

purl=${PROBE_URL:-}
hurl=${HEALTHCHECKS_PROBE_URL:-}
if [ -z "$purl" ] || [ -z "$hurl" ]; then
  # Log, don't vanish — a wholly silent no-op is the shape of the wave-13
  # incident (a build that ran unmonitored for four days).
  echo "$tag: PROBE_URL/HEALTHCHECKS_PROBE_URL unset; THIS APP IS UNPROBED" >&2
  exit 0
fi

# -f + --retry-all-errors is what actually absorbs ONE blip of ANY class:
# plain --retry covers only timeouts and 408/429/5xx — not DNS flaps, refused/
# reset connections, TLS hiccups, or Cloudflare's own 52x codes, each of which
# would page on a single attempt. -f turns a bad HTTP code into a curl error so
# --retry-all-errors retries those too, and -w still emits the real code under
# -f, so the code stays the datum and the gate below still classifies. A
# PERSISTING failure exhausts the retries and reports the last code.
# --max-time is per attempt; --retry-max-time bounds when the last retry may
# START, so the true ceiling is 45+15=60s (the --retry lesson from
# dataguru-build@.service). Stderr is deliberately NOT discarded: curl's own
# diagnosis ("Could not resolve host ...") is the /fail incident's best
# journal evidence.
code=$(curl -fsS -o /dev/null -w '%{http_code}' \
        --max-time 15 --retry 2 --retry-all-errors --retry-delay 2 --retry-max-time 45 \
        "$purl")
rc=$?

if [ "$rc" -eq 0 ] && [ "$code" = "200" ]; then
  path=""; msg="ok"
else
  path="/fail"; msg="HTTP ${code:-000} (curl exit $rc) from $purl"
fi

# -f matters on THIS curl: a 404 from a wrong check UUID must not look like a
# delivered alarm. The %/ strip keeps a pasted-with-trailing-slash URL from
# producing //fail.
if ! curl -fsS -o /dev/null \
      --max-time 10 --retry 2 --retry-delay 1 --retry-max-time 20 \
      --data-raw "$tag: $msg" "${hurl%/}$path"; then
  echo "$tag: could NOT ping healthchecks.io (probe result: $msg);" \
       "if the probe also failed, the journal and systemctl --failed are all that is left" >&2
fi

if [ -n "$path" ]; then
  echo "$tag: PROBE FAILED — $msg" >&2
  exit 1
fi
exit 0
