#!/usr/bin/env bash
# Shared post-purge verification, sourced by every app's deploy/cf-purge.sh.
#
# WHY THIS EXISTS
# ---------------
# Cloudflare's purge API answers 200 {"success": true} whether or not it evicted
# anything. From 2026-05-11 to 2026-08-18 every crhk.guru build logged
# "cf-purge: purged 12 URLs" while evicting nothing, because the zone's cache
# rule matched only `http.request.method eq "GET"` and Cloudflare evaluates that
# same rule against the internal PURGE request (fixed in #177). Three months of
# a completely dead purge, with a success line in the journal every night. The
# only thing that would have caught it is looking at the edge afterwards.
#
# So: purge, then re-request one URL and check the edge actually let go of it.
#
# TWO TRAPS, BOTH LEARNED THE HARD WAY
# ------------------------------------
# 1. The probe MUST be a GET. `curl -I` sends HEAD, and the cache rules match
#    only GET (and PURGE) -- so a HEAD probe matches no cache rule and comes
#    back `cf-cache-status: DYNAMIC` on a page that is in fact perfectly cached.
#    A verifier built on `curl -I` would cry wolf on every build, forever. This
#    is not hypothetical: it produced a false "the homepage is uncached!"
#    reading while #175 was being re-measured on 2026-08-20.
#
# 2. A plain HIT is NOT failure. Between our purge and our probe, any visitor or
#    crawler can refill the edge, and that refilled copy is correct and fresh.
#    What cannot happen after a real eviction is a copy that is already OLD.
#    So the failure signal is `HIT` *with a large age*, never `HIT` alone.
#
# Everything here is advisory: it logs, and always returns 0. The snapshot is
# already promoted by the time a purge runs, and a build must never be marked
# failed because an edge probe was inconclusive.

# Seconds an edge copy may have lived and still be consistent with a successful
# purge. Anything older was demonstrably not evicted. Generous on purpose: the
# only thing being excluded is a copy that predates the purge, and those are
# hours old (a full edge TTL), not seconds.
CF_PURGE_MAX_AGE="${CF_PURGE_MAX_AGE:-60}"

# cf_purge_verify <url> [settle_seconds]
#
# Probes <url> and prints one line. Never fails, never exits.
#
# Every command substitution below carries `|| true`. crhkguru's cf-purge.sh runs
# under `set -euo pipefail`, and a bare `x=$(cmd)` assignment PROPAGATES cmd's
# exit status -- so one SIGPIPE from a probe would abort the caller mid-purge.
# The whole point of this file is to be unable to break the thing it observes.
cf_purge_verify() {
  local url="$1" settle="${2:-5}"
  local hdrs status cache age

  # Give the purge time to land in the colo that answers us. Measured on
  # crhk.guru and hkjc.guru 2026-08-20: MISS by t+6s, so 5s is the shortest
  # honest wait. Too short and this reports a false failure.
  sleep "$settle" || true

  hdrs=$(/usr/bin/curl -sS -o /dev/null -D - --max-time 15 \
           -H 'Accept-Encoding: gzip' "$url" 2>/dev/null) || hdrs=""
  if [ -z "$hdrs" ]; then
    echo "cf-purge: WARNING unverified -- probe of $url failed (network? origin down?)" >&2
    return 0
  fi

  hdrs=$(printf '%s' "$hdrs" | tr -d '\r') || true
  status=$(printf '%s\n' "$hdrs" | awk '/^[Hh][Tt][Tt][Pp]/ {s=$2} END {print s+0}') || true
  cache=$(printf '%s\n' "$hdrs" | awk -F': ' 'tolower($1)=="cf-cache-status" {print toupper($2)}') || true
  age=$(printf '%s\n' "$hdrs" | awk -F': ' 'tolower($1)=="age" {print $2+0}') || true
  [ -n "$cache" ] || cache="(none)"
  [ -n "$age" ] || age=0

  if [ "$status" != "200" ]; then
    echo "cf-purge: WARNING unverified -- $url returned HTTP $status" >&2
    return 0
  fi

  case "$cache" in
    HIT)
      if [ "$age" -ge "$CF_PURGE_MAX_AGE" ]; then
        # The one real alarm. A copy this old cannot have survived an eviction.
        echo "cf-purge: WARNING PURGE DID NOT EVICT -- $url is still HIT with age=${age}s" \
             "after a purge the API reported as successful. The edge is serving content" \
             "from before the purge. Check the zone's cache rule still admits PURGE" \
             "(#175/#177): a rule matching only GET makes by-URL purge a silent no-op." >&2
      else
        echo "cf-purge: verified -- $url refilled (HIT, age=${age}s < ${CF_PURGE_MAX_AGE}s)"
      fi
      ;;
    MISS|EXPIRED|REVALIDATED|UPDATING|STALE)
      echo "cf-purge: verified -- $url is $cache (edge released it)"
      ;;
    DYNAMIC|BYPASS|NONE|"(none)")
      # Not a purge failure: this URL is not edge-cacheable at all, so purging
      # it was always a no-op. That is its own bug -- the cache rule does not
      # match a page we are treating as cached. crhk.guru shipped exactly this
      # for /browse, /new-companies and /statistics (#175).
      echo "cf-purge: WARNING $url is not edge-cached ($cache) -- purging it does nothing." \
           "Its path is missing from the zone's cache rule in deploy/site.toml." >&2
      ;;
    *)
      echo "cf-purge: unverified -- $url returned cf-cache-status: $cache" >&2
      ;;
  esac
  return 0
}
