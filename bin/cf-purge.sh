#!/usr/bin/env bash
# Purge the Cloudflare edge cache for the current app after a successful deploy.
#
# Inherits CF_CACHE_PURGE_TOKEN (+ CF_ZONE_ID and/or BASE_URL) from the caller's
# env (the systemd unit's EnvironmentFile=/etc/<app>/env). No-op unless the
# deploy succeeded ($SERVICE_RESULT=success) and a purge token is set, so
# manual/dev runs and apps with no token configured don't error. Purge
# failures are non-fatal — the code is already live — so this logs and
# always exits 0.
#
# Promoted from three near-identical clones in renavon-monorepo
# (bechirot/crescira/hkjcguru's deploy/cf-purge.sh); crhk.guru's own script
# does a much larger TARGETED purge of specific hub + sitemap URLs and stays
# app-owned rather than becoming a toolkit feature here — see deploy/converge.sh
# for the pattern an app uses to extend what this file does not cover.
#
# Lives in a script (not inline in a unit) on purpose: systemd unescapes `\"`
# before bash sees it, which mangles an inline `{"purge_everything":true}`
# body into invalid JSON (Cloudflare 400).
set -uo pipefail

[ "${SERVICE_RESULT:-}" = "success" ] || exit 0
[ -n "${CF_CACHE_PURGE_TOKEN:-}" ] || exit 0

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- zone id ---------------------------------------------------------------
# CF_ZONE_ID, if set, is an override and skips the lookup. Otherwise resolve
# it from the domain in BASE_URL the same way cf-converge.py does: a scoped
# token already sees its own zone in a name-filtered list, so the token
# itself answers "which zone is this?" with no separate Zone:Read grant.
zone="${CF_ZONE_ID:-}"
if [ -z "$zone" ] && [ -n "${BASE_URL:-}" ]; then
  dom=${BASE_URL#http://}; dom=${dom#https://}; dom=${dom%%/*}
  zone=$(curl -sS --max-time 10 \
    -H "Authorization: Bearer ${CF_CACHE_PURGE_TOKEN}" \
    "https://api.cloudflare.com/client/v4/zones?name=${dom}" \
    | python3 -c 'import sys,json; r=(json.load(sys.stdin).get("result") or []); print(r[0]["id"] if len(r)==1 else "")' 2>/dev/null || true)
fi
[ -n "$zone" ] || { echo "cf-purge: no zone id (CF_ZONE_ID unset and BASE_URL did not resolve one)" >&2; exit 0; }

# --- settle ------------------------------------------------------------------
# The reload immediately before this ExecStopPost only SENDS SIGHUP -- for a
# short window the old workers still answer, and anything the edge pulls in
# that window is the OLD content, which then sits at the edge for a full TTL:
# exactly the staleness the purge exists to prevent. Stated rather than left
# to whatever margin the zone lookup above happens to add by luck.
sleep "${CF_PURGE_SETTLE:-3}"

# Shared post-purge verification. Sourced defensively: an unverified purge is
# still a purge, so a missing helper must not stop us purging.
if [ -r "$SELF/cf-purge-verify.sh" ]; then
  # shellcheck disable=SC1091
  . "$SELF/cf-purge-verify.sh"
else
  echo "cf-purge: WARNING verification helper missing at $SELF/cf-purge-verify.sh" >&2
  cf_purge_verify() { :; }
fi

resp=$(curl -sS -w '\n%{http_code}' -X POST \
  "https://api.cloudflare.com/client/v4/zones/${zone}/purge_cache" \
  -H "Authorization: Bearer ${CF_CACHE_PURGE_TOKEN}" \
  -H "Content-Type: application/json" \
  --data '{"purge_everything":true}') || { echo "cf-purge: curl error" >&2; exit 0; }

code=${resp##*$'\n'}
body=${resp%$'\n'*}
if [ "$code" = "200" ]; then
  echo "cf-purge: ok (zone $zone)"
  [ -n "${BASE_URL:-}" ] && cf_purge_verify "${BASE_URL%/}/"
else
  echo "cf-purge: HTTP $code — $body" >&2
fi
exit 0
