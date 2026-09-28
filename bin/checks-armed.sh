#!/usr/bin/env bash
# checks-armed.sh — assert every alarm for this fleet is actually ARMED.
#
# The failure this exists for: healthchecks accepts a ping to a PAUSED check,
# answers `200 OK`, and discards it. Every layer on every box then reports
# success — the probe uses `curl -f` and logs only on failure, the poller's
# ping is a leaf — so a 200 reads as "delivered". One day every check on a
# fleet was paused at once and nothing anywhere said so. That is the monitor
# being fine while the alarm is gone, which is precisely what dead-man
# switches cannot see one level up.
#
# What this asserts, over every check carrying HEALTHCHECKS_SWEEP_TAG:
#   1. the sweep returned at least HEALTHCHECKS_EXPECTED_MIN checks
#   2. no check is paused
#   3. every check with a SIMPLE period has pinged within timeout + grace
#
# Assertion 3 skips cron-scheduled checks (`schedule` set, `timeout` null):
# staleness is healthchecks' OWN job and it does it for both schedule types,
# so 3 is a cross-check of its bookkeeping, not the point. The point is 1 and
# 2 — the two things healthchecks structurally cannot report about itself,
# because a paused check and a deleted one both look like silence.
#
# A `down` check is NOT a failure here and must never become one. Down means
# the alarm FIRED — it is armed and working. Reporting it as a violation would
# make this go red for the duration of every real incident, and it would be
# silenced as noise within a week. Down checks are listed as information.
#
# Assertion 1 is not a formality. "Zero checks returned" is exactly what a
# revoked key, a wrong API URL or a tag typo produces, and without a floor an
# empty list satisfies 2 and 3 vacuously — green precisely when it has lost
# sight of everything. A bad key returns `{"error": "wrong api key"}` with
# HTTP 401, and a reader that does `.get("checks", [])` prints "0 checks".
#
# It is safe for this to report into healthchecks like everything else: tag
# its own check with the sweep tag and it asserts over ITSELF. Pause it and
# the next run — the systemd timer is independent of healthchecks — sees its
# own check paused, pings /fail (discarded, as expected) and exits 1, so
# `systemctl --failed` carries it.
#
# A first run IN PROGRESS is not "never pinged". On a fresh install this
# script's own check is brand new BECAUSE this is its first run, and failing
# on that sent one spurious down alert per install (its /fail then counts as a
# ping, so run two passed). So each run sends /start before it reads the API:
# healthchecks records a start without touching last_ping (hc/api/models.py,
# "Don't update last_ping"), and reports it as `started: true`. A check that
# has never pinged but is started is a job on its first run, this one or any
# other, and is listed as information. No URL-to-check matching is needed,
# which a read-only key could not do anyway (it gets no ping_url). If that
# first run never finishes, healthchecks turns the start into `down` after
# the grace period, which is the alarm firing.
#
# Composition, because these three are easy to conflate:
#   * a canary        — can the instance still ALERT?     (instance-wide)
#   * this script     — is each alarm ARMED?              (per-check)
#   * the dead-man    — did the job actually RUN?         (per-job)
# Each is blind to the other two's failure.
#
# An app that is probed from OFF the box (site.toml `probe_external = "<check
# name>"`, see host-converge.sh) has no on-box probe, so this is what notices
# if that external check disappears: given the app name, it also looks the
# named check up (by name or slug) across every check the API key can see and
# holds it to the same assertions. It need not carry the sweep tag, but a
# healthchecks API key sees ONE project, so the external check must live in
# the ops-env key's project. Absent is a violation: that is an app nobody probes.
#
# Env (from a root-only /etc/<app>/ops-env; the systemd manager reads it, so
# the service user never needs the file): HEALTHCHECKS_API_URL,
# HEALTHCHECKS_API_KEY, HEALTHCHECKS_SWEEP_TAG, HEALTHCHECKS_ARMED_URL (this
# script's own check), HEALTHCHECKS_EXPECTED_MIN (a floor, default 1).
#
# Exit: 0 when every assertion holds, 1 otherwise (after the /fail ping).
# Unset env is a logged no-op at exit 0 — env-check owns nagging about
# missing config, and this must not fail a box that never opted in.
set -u
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib/hc.sh"

app=${1:-}
SITE_TOML=${SITE_TOML:-/srv/$app/deploy/site.toml}

tag="site-checks-armed"
api=${HEALTHCHECKS_API_URL:-}
key=${HEALTHCHECKS_API_KEY:-}
hurl=${HEALTHCHECKS_ARMED_URL:-}
sweep_tag=${HEALTHCHECKS_SWEEP_TAG:-}
expected_min=${HEALTHCHECKS_EXPECTED_MIN:-1}

if [ -z "$api" ] || [ -z "$key" ]; then
  echo "$tag: HEALTHCHECKS_API_URL/HEALTHCHECKS_API_KEY unset; ALARMS ARE UNVERIFIED" >&2
  exit 0
fi
if [ -z "$sweep_tag" ]; then
  echo "$tag: HEALTHCHECKS_SWEEP_TAG unset (which checks are this fleet's?); ALARMS ARE UNVERIFIED" >&2
  exit 0
fi

# Before the read, so this run's own check shows as started: see the header.
hc_ping "$hurl" /start "$tag: sweeping tag=$sweep_tag"

# -f so a 401/403/404 becomes a curl error rather than a body we might parse
# as an empty check list — assertion 1's trap, closed one layer earlier.
body=$(${CURL:-curl} -fsS --max-time 20 --retry 2 --retry-all-errors --retry-delay 2 \
        --retry-max-time 45 -H "X-Api-Key: $key" "${api%/}/checks/?tag=${sweep_tag}") || {
  msg="could not read the healthchecks API at ${api%/}/checks/ (curl exit $?)"
  echo "$tag: $msg" >&2
  hc_ping "$hurl" /fail "$tag: $msg"
  exit 1
}

# The app's external probe, if it declares one. --app-keys: the key is per
# app, and /srv/<app> is the app's own dir in workspace mode too.
required=""
if [ -n "$app" ] && [ -r "$SITE_TOML" ]; then
  required=$(python3 "$(dirname "${BASH_SOURCE[0]}")/site-config.py" --app-keys "$SITE_TOML" 2>/dev/null \
               | sed -n "s/^export PROBE_EXTERNAL=//p" | tail -1 | tr -d "'\"")
fi
all_file=""
if [ -n "$required" ]; then
  all_file=$(mktemp); trap 'rm -f "$all_file"' EXIT
  ${CURL:-curl} -fsS --max-time 20 --retry 2 --retry-all-errors --retry-delay 2 \
      --retry-max-time 45 -H "X-Api-Key: $key" "${api%/}/checks/" > "$all_file" || {
    msg="could not read the healthchecks API at ${api%/}/checks/ to find $required (curl exit $?)"
    echo "$tag: $msg" >&2
    hc_ping "$hurl" /fail "$tag: $msg"
    exit 1
  }
fi

report=$(printf '%s' "$body" | EXPECTED_MIN="$expected_min" SWEEP_TAG="$sweep_tag" \
           REQUIRED="$required" ALL_CHECKS_FILE="$all_file" python3 -c '
import json, os, sys
from datetime import datetime, timezone

expected_min = int(os.environ["EXPECTED_MIN"])
sweep_tag = os.environ["SWEEP_TAG"]
doc = json.load(sys.stdin)
checks = doc.get("checks")
if checks is None:
    print(f"the API response has no `checks` key — got {sorted(doc)[:5]}")
    sys.exit(1)

problems = []
if len(checks) < expected_min:
    problems.append(
        f"the tag={sweep_tag} sweep returned {len(checks)} check(s), "
        f"below the floor of {expected_min} — a revoked key, a wrong API URL "
        f"or a retagged check would look exactly like this"
    )

# An external probe named by the app (probe_external): looked up by name or
# slug among every check the key can see, then judged like a swept one.
required = os.environ.get("REQUIRED", "")
if required:
    with open(os.environ["ALL_CHECKS_FILE"]) as fh:
        visible = json.load(fh).get("checks") or []
    found = [c for c in visible if required in (c.get("name"), c.get("slug"))]
    if not found:
        problems.append(
            f"{required}: declared as this app probe_external but no such check "
            f"is visible to this API key — the app is UNPROBED"
        )
    names = {c.get("name") for c in checks}
    checks = checks + [c for c in found[:1] if c.get("name") not in names]

now = datetime.now(timezone.utc)
firing = []
first_run = []
for c in sorted(checks, key=lambda x: x.get("name", "")):
    name = c.get("name", "?")
    if c.get("status") == "paused":
        problems.append(f"{name}: PAUSED — its pings are accepted and discarded")
        continue
    if c.get("status") == "down":
        # Armed and firing. Information, never a violation — see the header.
        firing.append(name)
    timeout, last = c.get("timeout"), c.get("last_ping")
    if not timeout:
        # Cron-scheduled: staleness belongs to healthchecks itself. (No
        # apostrophes anywhere in this block: it is shell single-quoted.)
        continue
    if not last:
        if c.get("started"):
            first_run.append(name)   # a first run in progress; see the header
            continue
        problems.append(f"{name}: has never been pinged")
        continue
    age = (now - datetime.fromisoformat(last.replace("Z", "+00:00"))).total_seconds()
    limit = timeout + (c.get("grace") or 0)
    if age > limit:
        problems.append(
            f"{name}: last ping {age / 60:.0f} min ago, past its "
            f"{limit / 60:.0f} min period+grace"
        )

joined = ", ".join(firing)
note = f" ({len(firing)} currently firing: {joined})" if firing else ""
if first_run:
    starting = ", ".join(first_run)
    note += f" ({len(first_run)} on a first run: {starting})"
if problems:
    print("; ".join(problems) + note)
    sys.exit(1)
print(f"{len(checks)} check(s) tagged {sweep_tag}: all armed{note}")
')
rc=$?

if [ "$rc" -eq 0 ]; then
  hc_ping "$hurl" "" "$tag: $report"
  echo "$tag: $report"
  exit 0
fi
hc_ping "$hurl" /fail "$tag: $report"
echo "$tag: ALARMS NOT ARMED — $report" >&2
exit 1
