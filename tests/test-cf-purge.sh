#!/usr/bin/env bash
# Scenario tests for bin/cf-purge.sh + bin/cf-purge-verify.sh. `curl` and
# `sleep` are stubs on PATH, so nothing here ever reaches the network or
# actually waits.
#
# Why this exists (ported from renavon-monorepo's test-cf-purge.sh, which
# statically checked four near-identical app-owned clones for exactly two
# regressions that had shipped for real): a FAILED unit run purging the edge
# anyway (the SERVICE_RESULT gate missing, or inverted, or placed after the
# first network call), and the purge POST using `curl -f` so a Cloudflare
# 403/429/5xx aborts the script under `set -euo pipefail` and marks an
# otherwise-successful deploy as failed. site-deploy has exactly one copy of
# this script, so the port is behavioural rather than structural: stub curl,
# assert it is (or is not) called, and assert what it was called WITH.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); [ -s "$T/out.txt" ] && sed 's/^/         | /' "$T/out.txt" | tail -8; }
check() { local desc=$1; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }

T=$(mktemp -d); export T
if [ -n "${KEEP_SANDBOX:-}" ]; then trap 'echo "sandbox kept at $T"' EXIT; else trap 'rm -rf "$T"' EXIT; fi
export STUB_LOG="$T/calls.log"
mkdir -p "$T/bin"

# STUB_ZONE_LOOKUP  -- result of the /zones?name= GET (a zone id, or empty for "not found")
# STUB_PURGE_CODE   -- HTTP code the purge_cache POST answers (default 200)
# STUB_PURGE_FAIL   -- curl itself errors on the purge POST
# Anything else is cf_purge_verify's plain GET probe (`curl ... -D -` writes
# response headers to stdout, which -o /dev/null leaves as the only output).
cat > "$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$STUB_LOG"
case " $* " in
  *'zones?name='*)
    zone="${STUB_ZONE_LOOKUP:-}"
    if [ -n "$zone" ]; then
      printf '{"success":true,"result":[{"id":"%s"}]}' "$zone"
    else
      printf '{"success":true,"result":[]}'
    fi
    ;;
  *'purge_cache'*)
    [ -n "${STUB_PURGE_FAIL:-}" ] && exit 7
    code="${STUB_PURGE_CODE:-200}"
    printf '{"success":true}\n%s' "$code"
    ;;
  *)
    printf 'HTTP/1.1 200 OK\r\nCf-Cache-Status: MISS\r\n\r\n'
    ;;
esac
STUB
cat > "$T/bin/sleep" <<'STUB'
#!/usr/bin/env bash
echo "sleep $*" >> "$STUB_LOG"
exit 0
STUB
chmod +x "$T/bin"/*
export PATH="$T/bin:$PATH"

reset_log() { : > "$STUB_LOG"; }
called() { grep -qF -e "$1" "$STUB_LOG"; }
not_called() { ! grep -qF -e "$1" "$STUB_LOG"; }
run() { env "$@" bash "$ROOT/bin/cf-purge.sh" > "$T/out.txt" 2>&1; echo $? > "$T/rc.txt"; }
rc() { cat "$T/rc.txt"; }

echo "1. SERVICE_RESULT != success: no curl at all, exit 0"
reset_log; run CF_CACHE_PURGE_TOKEN=t CF_ZONE_ID=z1 SERVICE_RESULT=failed
check "exit 0"          [ "$(rc)" = 0 ]
check "no curl"         [ ! -s "$STUB_LOG" ]

echo "2. no CF_CACHE_PURGE_TOKEN: no curl at all, even on success"
reset_log; run SERVICE_RESULT=success CF_ZONE_ID=z1
check "exit 0"          [ "$(rc)" = 0 ]
check "no curl"         [ ! -s "$STUB_LOG" ]

echo "3. CF_ZONE_ID set: purges that zone directly, no zone lookup"
reset_log; run SERVICE_RESULT=success CF_CACHE_PURGE_TOKEN=t CF_ZONE_ID=z1
check "exit 0"          [ "$(rc)" = 0 ]
check "purged z1"       called "zones/z1/purge_cache"
check "no zone lookup"  not_called "zones?name="

echo "4. CF_ZONE_ID unset, BASE_URL set: resolves the zone, then purges it"
reset_log; run SERVICE_RESULT=success CF_CACHE_PURGE_TOKEN=t BASE_URL=https://site.example/ STUB_ZONE_LOOKUP=zr
check "exit 0"          [ "$(rc)" = 0 ]
check "looked up"       called "zones?name=site.example"
check "purged resolved" called "zones/zr/purge_cache"

echo "5. CF_ZONE_ID unset, BASE_URL unset: no zone, exit 0, explains why, never purges"
reset_log; run SERVICE_RESULT=success CF_CACHE_PURGE_TOKEN=t
check "exit 0"          [ "$(rc)" = 0 ]
check "said why"        grep -qi "no zone id" "$T/out.txt"
check "never purged"    not_called "purge_cache"

echo "6. the purge POST never uses -f/--fail (a 403 must be data, not an abort)"
reset_log; run SERVICE_RESULT=success CF_CACHE_PURGE_TOKEN=t CF_ZONE_ID=z1
check "no -f"           bash -c '! grep -E "(^|[[:space:]])(-f|--fail)([[:space:]]|$)" "$STUB_LOG"'

echo "7. CF_PURGE_SETTLE controls the sleep; default 3"
reset_log; run SERVICE_RESULT=success CF_CACHE_PURGE_TOKEN=t CF_ZONE_ID=z1
check "default settle"  called "sleep 3"
reset_log; run SERVICE_RESULT=success CF_CACHE_PURGE_TOKEN=t CF_ZONE_ID=z1 CF_PURGE_SETTLE=9
check "custom settle"   called "sleep 9"

echo "8. success + BASE_URL set: cf_purge_verify probes it"
reset_log; run SERVICE_RESULT=success CF_CACHE_PURGE_TOKEN=t CF_ZONE_ID=z1 BASE_URL=https://site.example/
check "exit 0"          [ "$(rc)" = 0 ]
check "probed"          called "curl -sS -o /dev/null -D - --max-time 15 -H Accept-Encoding: gzip https://site.example/"

echo "9. success, no BASE_URL: cf_purge_verify never runs (nothing to probe)"
reset_log; run SERVICE_RESULT=success CF_CACHE_PURGE_TOKEN=t CF_ZONE_ID=z1
check "exit 0"          [ "$(rc)" = 0 ]
check "no probe"        not_called "-D -"

echo "10. a non-200 purge response: logged, no verify, still exit 0"
reset_log; run SERVICE_RESULT=success CF_CACHE_PURGE_TOKEN=t CF_ZONE_ID=z1 BASE_URL=https://site.example/ STUB_PURGE_CODE=403
check "exit 0"          [ "$(rc)" = 0 ]
check "said so"         grep -q "HTTP 403" "$T/out.txt"
check "no probe"        not_called "-D -"

echo "11. curl itself fails on the purge POST: logged, exit 0"
reset_log; run SERVICE_RESULT=success CF_CACHE_PURGE_TOKEN=t CF_ZONE_ID=z1 STUB_PURGE_FAIL=1
check "exit 0"          [ "$(rc)" = 0 ]
check "said so"         grep -qi "curl error" "$T/out.txt"

echo "12. cf-purge-verify.sh missing: warns, purge still succeeds"
mv "$ROOT/bin/cf-purge-verify.sh" "$T/cf-purge-verify.sh.bak"
reset_log; run SERVICE_RESULT=success CF_CACHE_PURGE_TOKEN=t CF_ZONE_ID=z1 BASE_URL=https://site.example/
check "exit 0"          [ "$(rc)" = 0 ]
check "warned"          grep -qi "verification helper missing" "$T/out.txt"
check "still purged"    called "purge_cache"
mv "$T/cf-purge-verify.sh.bak" "$ROOT/bin/cf-purge-verify.sh"

echo
if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; else echo "all checks passed"; fi
exit $((fails > 0))
