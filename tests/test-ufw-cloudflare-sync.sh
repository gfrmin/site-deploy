#!/usr/bin/env bash
# Scenario tests for bin/ufw-cloudflare-sync.sh: diff-apply Cloudflare's
# published ranges onto ufw's 80/443 allow-list, touching nothing else.
#
# `ufw` and `curl` are stubs on PATH. The ufw stub keeps a flat state file of
# "port|cidr|comment" rows and renders `ufw status numbered` in the real
# format (including the trailing "# comment" and the "(v6)" port suffix),
# because the script's own parser has to survive that format, not a
# convenient fake one.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); [ -s "$T/out.txt" ] && sed 's/^/         | /' "$T/out.txt" | tail -10; }
check() { local desc=$1; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }

T=$(mktemp -d)
if [ -n "${KEEP_SANDBOX:-}" ]; then trap 'echo "sandbox kept at $T"' EXIT; else trap 'rm -rf "$T"' EXIT; fi
export STUB_LOG="$T/calls.log"
STATE="$T/ufw-state"; export STUB_UFW_STATE="$STATE"
: > "$STATE"
mkdir -p "$T/bin" "$T/nouwf"

cat > "$T/bin/ufw" <<'STUB'
#!/usr/bin/env bash
echo "ufw $*" >> "$STUB_LOG"
STATE="$STUB_UFW_STATE"
touch "$STATE"

find_after() { local key=$1; shift; local prev=""; for a in "$@"; do [ "$prev" = "$key" ] && { echo "$a"; return; }; prev=$a; done; }

case "$1" in
  status)
    echo "Status: active"
    echo
    echo "     To                         Action      From"
    echo "     --                         ------      ----"
    n=0
    while IFS='|' read -r port cidr comment; do
      [ -n "$port" ] || continue
      n=$((n + 1))
      case "$cidr" in *:*) portcol="$port/tcp (v6)" ;; *) portcol="$port/tcp" ;; esac
      line=$(printf '[%2d] %-27s ALLOW IN    %s' "$n" "$portcol" "$cidr")
      [ -n "$comment" ] && line="$line            # $comment"
      echo "$line"
    done < "$STATE"
    ;;
  allow)
    shift
    port=$(find_after port "$@"); cidr=$(find_after from "$@"); comment=$(find_after comment "$@")
    [ -n "${STUB_FAIL_ADD:-}" ] && exit 1
    entry="$port|$cidr|$comment"
    grep -qxF "$entry" "$STATE" 2>/dev/null || echo "$entry" >> "$STATE"
    ;;
  delete)
    shift; shift # delete allow ...
    port=$(find_after port "$@"); cidr=$(find_after from "$@"); comment=$(find_after comment "$@")
    [ -n "${STUB_FAIL_DELETE:-}" ] && exit 1
    entry="$port|$cidr|$comment"
    grep -vxF "$entry" "$STATE" > "$STATE.tmp" 2>/dev/null || : > "$STATE.tmp"
    mv "$STATE.tmp" "$STATE"
    ;;
  *) ;;
esac
exit 0
STUB

V4_FILE="$T/v4.txt"; V6_FILE="$T/v6.txt"
printf '1.1.1.0/24\n2.2.2.0/24\n' > "$V4_FILE"
printf '2400:cb00::/32\n' > "$V6_FILE"
cat > "$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$STUB_LOG"
url="${*: -1}"
case "$url" in
  *ips-v4*) [ -n "${STUB_FAIL_V4:-}" ] && exit 22; cat "$STUB_V4_FILE" ;;
  *ips-v6*) [ -n "${STUB_FAIL_V6:-}" ] && exit 22; cat "$STUB_V6_FILE" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$T/bin"/*
export PATH="$T/bin:$PATH" STUB_V4_FILE="$V4_FILE" STUB_V6_FILE="$V6_FILE"
# A PATH with curl and the coreutils the script needs but NO ufw at all, for
# the "no ufw on this box" case — must not just shadow it, since anything
# later in PATH (e.g. a real /usr/bin/ufw on a dev box) would still be found.
cp "$T/bin/curl" "$T/nouwf/curl"; chmod +x "$T/nouwf/curl"
for tool in sed comm mktemp grep cat bash; do ln -s "$(command -v "$tool")" "$T/nouwf/$tool"; done

reset_log() { : > "$STUB_LOG"; }
called() { grep -qF -e "$1" "$STUB_LOG"; }
not_called() { ! grep -qF -e "$1" "$STUB_LOG"; }
run() { bash "$ROOT/bin/ufw-cloudflare-sync.sh" > "$T/out.txt" 2>&1; echo $? > "$T/rc.txt"; }
rc() { cat "$T/rc.txt"; }
in_state() { grep -q -- "$1" "$STATE"; }
not_in_state() { ! grep -q -- "$1" "$STATE"; }

# A rule an operator (or harden.sh) added by hand — never carries the tag —
# plus the tailnet rule. Neither is ever the sync script's to touch.
printf '22|Anywhere on tailscale0|\n443|9.9.9.9/32|\n' >> "$STATE"

echo "1. a fresh box: the cross product of ranges x {80,443} is added; hand rules untouched"
reset_log; run
check "exit 0"                          [ "$(rc)" = 0 ]
check "added v4 range on 443"           called "allow from 1.1.1.0/24 to any port 443 proto tcp comment cf-sync"
check "added v4 range on 80"            called "allow from 1.1.1.0/24 to any port 80 proto tcp comment cf-sync"
check "added second v4 range"           called "allow from 2.2.2.0/24 to any port 443 proto tcp comment cf-sync"
check "added v6 range"                  called "allow from 2400:cb00::/32 to any port 443 proto tcp comment cf-sync"
check "6 rules now tagged"              [ "$(grep -c 'cf-sync' "$STATE")" = 6 ]
check "tailnet rule still there"        grep -q "tailscale0" "$STATE"
check "hand-added rule still there"     grep -q "9.9.9.9/32" "$STATE"
check "never reset"                     not_called "ufw reset"
check "never deleted the hand rule"     not_called "delete allow from 9.9.9.9/32"
check "never touched tailscale rule"    not_called "tailscale0"

echo "2. re-run with nothing changed: silent, idempotent"
reset_log; run
check "exit 0"                          [ "$(rc)" = 0 ]
check "no allow calls"                  not_called "ufw allow"
check "no delete calls"                 not_called "ufw delete"

echo "3. Cloudflare drops a range and adds another: old rules removed, new ones added, hand rules untouched"
printf '1.1.1.0/24\n3.3.3.0/24\n' > "$V4_FILE"
reset_log; run
check "exit 0"                          [ "$(rc)" = 0 ]
check "removed stale range on 443"      called "delete allow from 2.2.2.0/24 to any port 443 proto tcp comment cf-sync"
check "removed stale range on 80"       called "delete allow from 2.2.2.0/24 to any port 80 proto tcp comment cf-sync"
check "added new range"                 called "allow from 3.3.3.0/24 to any port 443 proto tcp comment cf-sync"
check "stale range gone from state"     not_in_state "2.2.2.0/24"
check "kept range untouched (no re-add)" not_called "allow from 1.1.1.0/24"
check "hand rule survived a real diff"  grep -q "9.9.9.9/32" "$STATE"

echo "4. curl fails fetching v4: refuses outright, touches nothing"
reset_log
before=$(cat "$STATE")
STUB_FAIL_V4=1 run
check "exit 1"                          [ "$(rc)" = 1 ]
check "said so"                         grep -qi "could not fetch" "$T/out.txt"
check "no ufw calls at all"             not_called "ufw allow"
check "state unchanged"                 [ "$(cat "$STATE")" = "$before" ]

echo "5. an empty range list is treated as a fetch failure, not as 'delete everything'"
: > "$V4_FILE"
reset_log; before=$(cat "$STATE")
run
check "exit 1"                          [ "$(rc)" = 1 ]
check "said so"                         grep -qi "empty" "$T/out.txt"
check "state unchanged"                 [ "$(cat "$STATE")" = "$before" ]
printf '1.1.1.0/24\n3.3.3.0/24\n' > "$V4_FILE"

echo "6. no ufw on this box: refuses with a clear message"
reset_log
PATH="$T/nouwf" run
check "exit 1"                          [ "$(rc)" = 1 ]
check "said so"                         grep -qi "no ufw" "$T/out.txt"

echo "7. a rule add fails: counted, reported, non-zero exit, but other rules still applied"
sed -i '/3.3.3.0/d' "$STATE"
reset_log; STUB_FAIL_ADD=1 run
check "exit 1"                          [ "$(rc)" = 1 ]
check "said FAILED"                     grep -q "UFW-CLOUDFLARE-SYNC FAILED" "$T/out.txt"

echo
if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; else echo "all checks passed"; fi
exit $((fails > 0))
