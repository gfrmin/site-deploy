#!/usr/bin/env bash
# Tests for lib/hc.sh (the ping leaf + http_probe), bin/hc-unit-result.sh
# (the ExecStopPost= backstop) and bin/health-probe.sh. A curl stub on PATH
# records every call and can be told what code to answer.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); [ -s "$T/out.txt" ] && sed 's/^/         | /' "$T/out.txt" | tail -6; }
check() { local desc=$1; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export STUB_LOG="$T/calls.log"
mkdir -p "$T/bin"
cat > "$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$STUB_LOG"
case "$*" in
  *hc.example*) [ -n "${STUB_PING_FAIL:-}" ] && exit 22; exit 0 ;;
esac
# a probe: answer STUB_PROBE_CODE (default 200); -f turns >=400 into exit 22
code="${STUB_PROBE_CODE:-200}"
[ "$code" = 000 ] && exit 7
if [ "$code" -ge 400 ] && printf '%s\n' "$@" | grep -qxE -- '-f|-fsS'; then printf '%s' "$code"; exit 22; fi
printf '%s' "$code"; exit 0
STUB
chmod +x "$T/bin/curl"; export PATH="$T/bin:$PATH"
reset_log() { : > "$STUB_LOG"; }
called() { grep -qF -e "$1" "$STUB_LOG"; }
not_called() { ! grep -qF -e "$1" "$STUB_LOG"; }
: > "$T/out.txt"

echo "── lib/hc.sh ──"
# shellcheck disable=SC1091
. "$ROOT/lib/hc.sh"

echo "1. hc_ping is a leaf: a failed ping returns 0 and says so on stderr"
reset_log
STUB_PING_FAIL=1 hc_ping "https://hc.example/u1" /fail "boom" 2> "$T/out.txt"; rc=$?
check "returned 0"                 [ "$rc" = 0 ]
check "posted the body"            called "--data-raw boom"
check "hit /fail"                  called "https://hc.example/u1/fail"
check "used -f (a 404 is not a delivered ping)" bash -c 'grep -q -- "-fsS" "$STUB_LOG"'
check "warned"                     grep -qi "could not ping" "$T/out.txt"

echo "2. an unset URL is a silent no-op, never a call"
reset_log; hc_ping "" "" "x"; rc=$?
check "returned 0"                 [ "$rc" = 0 ]
check "no curl"                    [ ! -s "$STUB_LOG" ]

echo "3. a pasted trailing slash cannot produce //fail"
reset_log; hc_ping "https://hc.example/u1/" /fail "x"
check "single slash"               called "https://hc.example/u1/fail"
check "no double slash"            not_called "u1//fail"

echo "4. http_probe echoes the code and returns curl's status, absorbing one blip"
reset_log; code=$(http_probe https://site.example/health); rc=$?
check "200"                        [ "$code" = 200 ]
check "rc 0"                       [ "$rc" = 0 ]
check "retries all error classes"  called "--retry-all-errors"
code=$(STUB_PROBE_CODE=503 http_probe https://site.example/health); rc=$?
check "503 reported"               [ "$code" = 503 ]
check "rc non-zero"                [ "$rc" != 0 ]
code=$(STUB_PROBE_CODE=000 http_probe https://site.example/health); rc=$?
check "000 when nothing printed"   [ "$code" = 000 ]

echo "── bin/hc-unit-result.sh (ExecStopPost backstop) ──"
run_result() { env "$@" bash "$ROOT/bin/hc-unit-result.sh" deploy > "$T/out.txt" 2>&1; echo $? > "$T/rc.txt"; }
echo "5. success is NOT pinged here (the script owns the success edge)"
reset_log; run_result SERVICE_RESULT=success HEALTHCHECKS_DEPLOY_URL=https://hc.example/d1
check "no curl"                    [ ! -s "$STUB_LOG" ]
check "exit 0"                     [ "$(cat "$T/rc.txt")" = 0 ]
echo "6. a non-success result pings /fail with the result"
reset_log; run_result SERVICE_RESULT=timeout HEALTHCHECKS_DEPLOY_URL=https://hc.example/d1
check "pinged /fail"               called "https://hc.example/d1/fail"
check "named the result"           called "timeout"
check "exit 0"                     [ "$(cat "$T/rc.txt")" = 0 ]
echo "7. unset URL: nothing"
reset_log; run_result SERVICE_RESULT=timeout
check "no curl"                    [ ! -s "$STUB_LOG" ]

echo "── bin/health-probe.sh ──"
run_probe() { env "$@" bash "$ROOT/bin/health-probe.sh" app > "$T/out.txt" 2>&1; echo $? > "$T/rc.txt"; }
echo "8. 200 -> pings the check root, exit 0"
reset_log; run_probe PROBE_URL=https://site.example/health HEALTHCHECKS_PROBE_URL=https://hc.example/p1
check "probed"                     called "https://site.example/health"
check "pinged root"                bash -c 'grep -q "https://hc.example/p1 *$\|https://hc.example/p1$" "$STUB_LOG"'
check "no /fail"                   not_called "/p1/fail"
check "exit 0"                     [ "$(cat "$T/rc.txt")" = 0 ]
echo "9. 503 -> pings /fail with the evidence, exit 1"
reset_log; run_probe PROBE_URL=https://site.example/health HEALTHCHECKS_PROBE_URL=https://hc.example/p1 STUB_PROBE_CODE=503
check "pinged /fail"               called "https://hc.example/p1/fail"
check "evidence in body"           called "HTTP 503"
check "exit 1"                     [ "$(cat "$T/rc.txt")" = 1 ]
echo "10. unset URLs -> logged no-op, exit 0"
reset_log; run_probe
check "no curl"                    [ ! -s "$STUB_LOG" ]
check "said unprobed"              grep -qi "UNPROBED" "$T/out.txt"
check "exit 0"                     [ "$(cat "$T/rc.txt")" = 0 ]
echo "11. site fine but the ping fails -> exit 0 (monitoring degradation is journal-only)"
reset_log; run_probe PROBE_URL=https://site.example/health HEALTHCHECKS_PROBE_URL=https://hc.example/p1 STUB_PING_FAIL=1
check "exit 0"                     [ "$(cat "$T/rc.txt")" = 0 ]
check "warned"                     grep -qi "could not ping" "$T/out.txt"

echo
if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; else echo "all checks passed"; fi
exit $((fails > 0))
