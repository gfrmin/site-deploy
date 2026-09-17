#!/usr/bin/env bash
# cf-converge-run.sh <app> [--dry-run] — root wrapper around cf-converge.py:
# derives the two facts an app cannot commit to its repo (the box's own
# public IP, and whether to write) and hands the rest to the pure, tested
# reconciler.
#
# Two callers, two systemd units:
#   cf-converge@.service  (no --dry-run) applies. The poller starts it
#                          --no-block when a deploy's ff range touches
#                          deploy/cloudflare.json.
#   cf-drift@.timer        (--dry-run) reports what WOULD change, daily,
#                          so a hand-edit at the Cloudflare dashboard is
#                          caught even on a day nobody deploys. A DIFF is
#                          itself the alertable condition here, not just a
#                          crash: drift IS what this check exists to catch.
set -uo pipefail

APP=${1:?usage: cf-converge-run.sh <app> [--dry-run]}
shift || true
DRY_RUN=""
[ "${1:-}" = --dry-run ] && DRY_RUN=1

ROOT="${HOST_ROOT:-}"
SELF="$ROOT/srv/site-deploy"
SRV="$ROOT/srv/$APP"
ETC="$ROOT/etc"
APP_ETC="$ETC/$APP"
DESIRED="$SRV/deploy/cloudflare.json"
CFC="${CFC:-$SELF/bin/cf-converge.py}"
PYTHON="${PYTHON:-python3}"

say() { echo "cf-converge-run[$APP]: $*"; }

[ -f "$DESIRED" ] || { say "no $DESIRED; nothing to converge"; exit 0; }

envval() { [ -r "$2" ] && sed -n "s/^$1=//p" "$2" | tail -1 | tr -d '"'"'"'[:space:]'; }

# The apex domain is the one fact cf-converge.py needs that is not already
# secret or box-local: it lives in site.toml (public, reviewable) rather than
# only in /etc/<app>/cf-env, though an override there wins for an app with no
# site.toml yet.
CF_DOMAIN=$(envval CF_DOMAIN "$APP_ETC/cf-env")
if [ -z "$CF_DOMAIN" ] && [ -f "$SRV/deploy/site.toml" ]; then
  CF_DOMAIN=$(python3 "$SELF/bin/site-config.py" "$SRV/deploy/site.toml" 2>/dev/null \
                | sed -n "s/^export CF_DOMAIN=//p" | tr -d "'\"")
fi
[ -n "$CF_DOMAIN" ] || {
  say "no cf_domain in deploy/site.toml and no CF_DOMAIN in /etc/$APP/cf-env; refusing"
  exit 1
}

# The box's own public IP, for the A records and any __PUBLIC_IP__ rule
# exemption. Order:
#   1. /etc/site-deploy/host.env PUBLIC_IP= -- an explicit override, for the
#      one case the box cannot infer: a reserved/floating IP where the
#      address Cloudflare must reach is not the box's own interface address.
#   2. DigitalOcean metadata (link-local, no egress needed).
#   3. an outbound echo -- cloud-agnostic fallback.
# Empty is safe: the reconciler then leaves A-record CONTENT untouched and
# still converges SSL, proxying and the rule phases.
derive_public_ip() {
  local ip
  ip=$(envval PUBLIC_IP "$ETC/site-deploy/host.env")
  [ -n "$ip" ] && { printf '%s' "$ip"; return; }
  ip=$(curl -s --max-time 3 http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address 2>/dev/null || true)
  case $ip in *.*.*.*) printf '%s' "$ip"; return ;; esac
  ip=$(curl -s -4 --max-time 5 https://cloudflare.com/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p' || true)
  case $ip in *.*.*.*) printf '%s' "$ip"; return ;; esac
  printf ''
}
PUBLIC_IP=$(derive_public_ip)
[ -n "$PUBLIC_IP" ] || say "WARNING could not derive public IP; A-record content and any __PUBLIC_IP__ rule left as-is"

args=(--desired "$DESIRED" --domain "$CF_DOMAIN" --public-ip "$PUBLIC_IP")
if [ -n "$DRY_RUN" ]; then args+=(--verbose); else args+=(--apply); fi

out=$("$PYTHON" "$CFC" "${args[@]}" 2>&1)
rc=$?
printf '%s\n' "$out"

if [ -n "$DRY_RUN" ] && [ -n "${HEALTHCHECKS_CF_DRIFT_URL:-}" ]; then
  # shellcheck disable=SC1091
  . "$SELF/lib/hc.sh"
  if [ "$rc" != 0 ] || [ -n "$out" ]; then
    hc_ping "$HEALTHCHECKS_CF_DRIFT_URL" /fail "cf-drift[$APP]: $out"
  else
    hc_ping "$HEALTHCHECKS_CF_DRIFT_URL" "" "cf-drift[$APP]: no drift"
  fi
fi
exit $rc
