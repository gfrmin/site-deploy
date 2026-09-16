#!/usr/bin/env bash
# Self-contained check of bin/checks-armed.sh. No network, no root, no
# healthchecks instance: the decision-making python is EXTRACTED from the real
# script and run against synthetic API payloads — not reimplemented here. A
# copy would drift, and this is exactly the code that must not.
#
# The script's whole value is that it fails LOUDLY in the cases where a naive
# reader goes quietly green, so those cases are pinned. It is also the one
# script whose core logic is python inside a shell single-quoted string, which
# creates a failure mode nothing else here has: one apostrophe in a comment
# closes the quote and the file stops being valid bash.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SRC="$ROOT/bin/checks-armed.sh"

fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); }
check() { local desc=$1; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }

[ -r "$SRC" ] || { fail "$SRC missing"; echo "1 check(s) failed"; exit 1; }

py_block=$(awk "/python3 -c '/{flag=1; next} /^')\$/{flag=0} flag" "$SRC")
check "extracted the embedded python"        [ -n "$py_block" ]
check "the embedded python has no single quote" bash -c '! printf "%s" "$1" | grep -q "'"'"'"' _ "$py_block"
check "the script parses as bash"            bash -n "$SRC"

run_case() {  # <name> <expected_exit> <min> <json> <must-contain>
  local name=$1 want=$2 min=$3 json=$4 needle=$5 out rc
  out=$(printf '%s' "$json" | EXPECTED_MIN="$min" SWEEP_TAG=fleet python3 -c "$py_block" 2>&1); rc=$?
  if [ "$rc" != "$want" ]; then fail "$name: exit $rc, wanted $want ($out)"
  elif ! printf '%s' "$out" | grep -qF "$needle"; then fail "$name: output lacked '$needle' ($out)"
  else pass "$name"; fi
}
up='{"name":"a","status":"up","timeout":300,"grace":600,"last_ping":"2099-01-01T00:00:00+00:00"}'
cron='{"name":"b","status":"up","timeout":null,"grace":7200,"last_ping":"1999-01-01T00:00:00+00:00"}'
paused='{"name":"c","status":"paused","timeout":300,"grace":600,"last_ping":"2099-01-01T00:00:00+00:00"}'
down='{"name":"d","status":"down","timeout":300,"grace":600,"last_ping":"2099-01-01T00:00:00+00:00"}'
stale='{"name":"e","status":"up","timeout":300,"grace":600,"last_ping":"1999-01-01T00:00:00+00:00"}'
never='{"name":"f","status":"new","timeout":300,"grace":600,"last_ping":null}'

# THE case this exists for: an empty list satisfies "none paused" vacuously.
run_case "an empty sweep fails rather than passing vacuously" 1 1 '{"checks":[]}' "below the floor"
# A 401 body parsed as JSON has no `checks` key; .get("checks", []) would print "0 checks" and look calm.
run_case "an error body is not read as an empty check list" 1 1 '{"error":"wrong api key"}' "no \`checks\` key"
run_case "a paused check is a violation" 1 1 "{\"checks\":[$up,$paused]}" "PAUSED"
# Down means the alarm FIRED, i.e. it is armed; a violation here gets muted as noise within a week.
run_case "a firing check is armed, not a violation" 0 1 "{\"checks\":[$up,$down]}" "currently firing"
run_case "a stale simple-period check is a violation" 1 1 "{\"checks\":[$stale]}" "past its"
run_case "a never-pinged check is reported as such, not as stale" 1 1 "{\"checks\":[$never]}" "never been pinged"
run_case "a cron-scheduled check is not judged for staleness" 0 1 "{\"checks\":[$cron]}" "all armed"
run_case "the happy path passes" 0 2 "{\"checks\":[$up,$cron]}" "all armed"

echo "── the shell half, with a curl stub ──"
T=$(mktemp -d); export T; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"; export STUB_LOG="$T/calls.log"
cat > "$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$STUB_LOG"
case "$*" in
  *"/checks/?tag="*) [ -n "${STUB_API_FAIL:-}" ] && exit 22
                     body=${STUB_API_BODY:-}; [ -n "$body" ] || body='{"checks":[]}'
                     printf '%s' "$body"; exit 0 ;;
esac
exit 0
STUB
chmod +x "$T/bin/curl"; export PATH="$T/bin:$PATH"
run_sh() { env "$@" bash "$SRC" > "$T/out.txt" 2>&1; echo $? > "$T/rc.txt"; }
ok_body='{"checks":[{"name":"a","status":"up","timeout":300,"grace":600,"last_ping":"2099-01-01T00:00:00+00:00"}]}'

: > "$STUB_LOG"; run_sh
check "unset env: logged no-op, exit 0"     [ "$(cat "$T/rc.txt")" = 0 ]
check "said UNVERIFIED"                     grep -q UNVERIFIED "$T/out.txt"
check "no curl"                             [ ! -s "$STUB_LOG" ]

: > "$STUB_LOG"; run_sh HEALTHCHECKS_API_URL=https://hc.example/api/v3 HEALTHCHECKS_API_KEY=k HEALTHCHECKS_SWEEP_TAG=fleet HEALTHCHECKS_ARMED_URL=https://hc.example/armed STUB_API_BODY="$ok_body"
check "happy path: exit 0"                  [ "$(cat "$T/rc.txt")" = 0 ]
check "swept the tag"                       grep -q "tag=fleet" "$STUB_LOG"
check "sent the key as a header"            grep -q "X-Api-Key: k" "$STUB_LOG"
check "pinged root"                         bash -c 'grep -q "https://hc.example/armed *$" "$STUB_LOG"'

: > "$STUB_LOG"; run_sh HEALTHCHECKS_API_URL=https://hc.example/api/v3 HEALTHCHECKS_API_KEY=k HEALTHCHECKS_SWEEP_TAG=fleet HEALTHCHECKS_ARMED_URL=https://hc.example/armed
check "empty sweep: exit 1"                 [ "$(cat "$T/rc.txt")" = 1 ]
check "pinged /fail"                        grep -q "armed/fail" "$STUB_LOG"
check "said NOT ARMED"                      grep -q "NOT ARMED" "$T/out.txt"

: > "$STUB_LOG"; run_sh HEALTHCHECKS_API_URL=https://hc.example/api/v3 HEALTHCHECKS_API_KEY=k HEALTHCHECKS_SWEEP_TAG=fleet HEALTHCHECKS_ARMED_URL=https://hc.example/armed STUB_API_FAIL=1
check "API unreachable: exit 1, /fail"      bash -c '[ "$(cat "$T/rc.txt")" = 1 ] && grep -q "armed/fail" "$STUB_LOG"'

: > "$STUB_LOG"; run_sh HEALTHCHECKS_API_URL=https://hc.example/api/v3 HEALTHCHECKS_API_KEY=k
check "no sweep tag: exit 0, says so"       bash -c '[ "$(cat "$T/rc.txt")" = 0 ] && grep -qi "SWEEP_TAG" "$T/out.txt"'

echo
if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; else echo "all checks passed"; fi
exit $((fails > 0))
