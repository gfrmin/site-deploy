#!/usr/bin/env bash
# Purge the Cloudflare edge cache for the current app after a successful deploy.
#
# Inherits CF_ZONE_ID + CF_CACHE_PURGE_TOKEN from the caller's env (the systemd unit's
# EnvironmentFile=/etc/<app>/env). No-op unless the deploy succeeded ($SERVICE_RESULT=success)
# and both CF_* vars are set, so manual/dev runs and apps with no token configured don't error.
# Purge failures are non-fatal — the code is already live — so we log and always exit 0.
#
# Lives in a script (not inline in a unit) on purpose: systemd unescapes `\"` before bash sees it,
# which mangles an inline `{"purge_everything":true}` body into invalid JSON (Cloudflare 400).
set -uo pipefail

# Absolute path by default (a systemd unit has a minimal PATH); overridable so
# the test harness can observe the purge without reaching Cloudflare.

[ "${SERVICE_RESULT:-}" = "success" ] || exit 0
[ -n "${CF_ZONE_ID:-}" ] && [ -n "${CF_CACHE_PURGE_TOKEN:-}" ] || exit 0

resp=$(${CURL:-/usr/bin/curl} -sS -w '\n%{http_code}' -X POST \
  "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/purge_cache" \
  -H "Authorization: Bearer ${CF_CACHE_PURGE_TOKEN}" \
  -H "Content-Type: application/json" \
  --data '{"purge_everything":true}') || { echo "cf-purge: curl error" >&2; exit 0; }

code=${resp##*$'\n'}
body=${resp%$'\n'*}
if [ "$code" = "200" ]; then
  echo "cf-purge: ok (zone ${CF_ZONE_ID})"
else
  echo "cf-purge: HTTP $code — $body" >&2
fi
exit 0
