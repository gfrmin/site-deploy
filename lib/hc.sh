# shellcheck shell=bash
# lib/hc.sh — the one place that knows how to REPORT to healthchecks.
#
# Source it; do not execute it:   . /srv/site-deploy/lib/hc.sh
#
# Three scripts (the poller, the probe, the backup) each need the same two
# things — "ping the dead-man" and "probe a URL without paging on one blip" —
# and copies of monitoring helpers drift in the one way that is invisible by
# construction: the broken thing is the thing that would have told you.
#
# THE RULE: a ping is a LEAF, never a wrapper. Monitoring must never be a hard
# dependency of the work it monitors. hc_ping ALWAYS returns 0; a failed ping
# is one line on stderr and nothing else. A deploy that runs unmonitored is a
# bad day; a deploy that did not run because its telemetry was down is a lost
# one.

# hc_ping <check-url> <suffix> [message]
#   suffix: "" (success), /start, /fail. Empty URL = silent no-op, so every
#   caller stays runnable by hand and under test.
#   POST body, not a query parameter: healthchecks takes the message as the
#   request body. ${url%/} so a pasted trailing slash cannot produce "//fail".
#   -f matters: a 404 from a wrong UUID must not look like a delivered ping.
hc_ping() {
  local url=${1:-} suffix=${2:-} msg=${3:-}
  [ -n "$url" ] || return 0
  ${CURL:-curl} -fsS -o /dev/null --max-time 10 --retry 2 --retry-delay 1 --retry-max-time 20 \
      --data-raw "$(printf '%s' "$msg" | tail -c 8000)" "${url%/}$suffix" \
    || echo "hc: could NOT ping ${url%/}$suffix (${msg:0:120})" >&2
  return 0
}

# http_probe <url>
#   Echoes the HTTP code, returns curl's exit status. Absorbs ONE blip of ANY
#   class, which a plain curl does not: plain --retry covers only timeouts and
#   408/429/5xx — not DNS flaps, refused/reset connections, TLS hiccups, or
#   Cloudflare's own 52x — each of which would page on a single attempt. -f
#   turns a bad HTTP code into a curl error so --retry-all-errors retries those
#   too, while -w still emits the real code, so the code stays the datum.
#   --max-time is PER ATTEMPT; --retry-max-time bounds when the last retry may
#   START, so the true ceiling is 45+15 = 60s. Stderr is deliberately NOT
#   discarded: curl's own diagnosis ("Could not resolve host") is the best
#   evidence a /fail body can carry.
http_probe() {
  local url=$1 code rc
  code=$(${CURL:-curl} -fsS -o /dev/null -w '%{http_code}' \
          --max-time 15 --retry 2 --retry-all-errors --retry-delay 2 --retry-max-time 45 \
          "$url")
  rc=$?
  # curl prints 000 on a connection failure but NOTHING on some early aborts,
  # so `|| echo 000` would concatenate into "000000". Substitute only when it
  # printed nothing at all.
  [ -n "$code" ] || code=000
  printf '%s' "$code"
  return $rc
}
