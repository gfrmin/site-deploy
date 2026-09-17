#!/usr/bin/env bash
# ufw-cloudflare-sync.sh — keep ufw's 80/443 allow-list equal to Cloudflare's
# CURRENT published ranges, diff-applied against ONLY the rules this script
# itself added (tagged with a ufw comment). Root. Idempotent.
#
# Run once by host/harden.sh right after the initial firewall goes up, and
# daily after that by ufw-cloudflare-sync.timer: Cloudflare's ranges change
# occasionally, and a box that never re-fetches them silently drifts into
# either rejecting a new range (visitors 5xx at the edge) or trusting a range
# Cloudflare has since given back to someone else.
#
# Never `ufw reset`s and never touches a rule without the tag below — not the
# tailnet allow, not :22, not anything an operator or harden.sh added by
# hand. reset would drop the tailnet rule too, and on a box with no other
# route in that is a lockout recoverable only from the provider's console.
set -uo pipefail

IPV4_URL="${CF_IPS_V4_URL:-https://www.cloudflare.com/ips-v4}"
IPV6_URL="${CF_IPS_V6_URL:-https://www.cloudflare.com/ips-v6}"
TAG="cf-sync"

say() { echo "ufw-cloudflare-sync: $*"; }

command -v ufw >/dev/null 2>&1 || { say "no ufw on this box; refusing"; exit 1; }

v4=$(curl -fsS "$IPV4_URL") || { say "could not fetch $IPV4_URL; leaving rules as they are"; exit 1; }
v6=$(curl -fsS "$IPV6_URL") || { say "could not fetch $IPV6_URL; leaving rules as they are"; exit 1; }
[ -n "$v4" ] || { say "empty IPv4 range list from $IPV4_URL; refusing to touch rules"; exit 1; }
[ -n "$v6" ] || { say "empty IPv6 range list from $IPV6_URL; refusing to touch rules"; exit 1; }

desired=$(mktemp); current=$(mktemp)
trap 'rm -f "$desired" "$current"' EXIT

{ for cidr in $v4 $v6; do for port in 80 443; do echo "$cidr $port"; done; done; } | sort -u > "$desired"

# Only rows THIS script tagged. `ufw status numbered` is the form that carries
# the comment; port and CIDR come out via sed rather than a column split,
# because the "(v6)" suffix ufw prints for an IPv6 rule shifts the column
# count that a plain `awk '{print $N}'` would rely on.
while IFS= read -r line; do
  case $line in *"# $TAG"*) ;; *) continue ;; esac
  port=$(printf '%s' "$line" | sed -nE 's/^\[[[:space:]]*[0-9]+\][[:space:]]+([0-9]+)\/tcp.*/\1/p')
  cidr=$(printf '%s' "$line" | sed -nE 's/.*ALLOW[[:space:]]+IN[[:space:]]+([^[:space:]]+).*/\1/p')
  [ -n "$port" ] && [ -n "$cidr" ] && echo "$cidr $port"
done < <(ufw status numbered 2>/dev/null) | sort -u > "$current"

failures=0
while read -r cidr port; do
  [ -n "$cidr" ] || continue
  if ufw allow from "$cidr" to any port "$port" proto tcp comment "$TAG" >/dev/null 2>&1; then
    say "added $cidr $port"
  else
    failures=$((failures + 1)); say "FAILED to add $cidr $port"
  fi
done < <(comm -23 "$desired" "$current")

while read -r cidr port; do
  [ -n "$cidr" ] || continue
  if ufw delete allow from "$cidr" to any port "$port" proto tcp comment "$TAG" >/dev/null 2>&1; then
    say "removed stale $cidr $port"
  else
    failures=$((failures + 1)); say "FAILED to remove stale $cidr $port"
  fi
done < <(comm -13 "$desired" "$current")

if [ "$failures" -gt 0 ]; then
  say "UFW-CLOUDFLARE-SYNC FAILED — $failures rule(s) did not converge"
  exit 1
fi
exit 0
