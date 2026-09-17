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
# Composition, because these three are easy to conflate:
#   * a canary        — can the instance still ALERT?     (instance-wide)
#   * this script     — is each alarm ARMED?              (per-check)
#   * the dead-man    — did the job actually RUN?         (per-job)
# Each is blind to the other two's failure.
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

# -f so a 401/403/404 becomes a curl error rather than a body we might parse
# as an empty check list — assertion 1's trap, closed one layer earlier.
body=$(${CURL:-curl} -fsS --max-time 20 --retry 2 --retry-all-errors --retry-delay 2 \
        --retry-max-time 45 -H "X-Api-Key: $key" "${api%/}/checks/?tag=${sweep_tag}") || {
  msg="could not read the healthchecks API at ${api%/}/checks/ (curl exit $?)"
  echo "$tag: $msg" >&2
  hc_ping "$hurl" /fail "$tag: $msg"
  exit 1
}

report=$(printf '%s' "$body" | EXPECTED_MIN="$expected_min" SWEEP_TAG="$sweep_tag" python3 -c '
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

now = datetime.now(timezone.utc)
firing = []
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
