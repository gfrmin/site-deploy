#!/usr/bin/env bash
# Scenario tests for bin/deferred-restart.sh: restart a deferred unit only when
# its main process still maps a replaced library (issue #49).
#
# No root, no systemd: HOST_ROOT= points the list and /proc at a sandbox, and
# `systemctl` is a stub that lists running units and their MainPIDs from files.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); [ -s "$T/out.txt" ] && sed 's/^/         | /' "$T/out.txt" | tail -8; }
check() { local desc=$1; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export STUB_LOG="$T/calls.log" STUB_UNITS="$T/units"
HR="$T/root"
mkdir -p "$T/bin" "$STUB_UNITS" "$HR/etc/site-deploy/deferred-restart"

# $STUB_UNITS/<unit> holds its MainPID; every file there is a running service.
cat > "$T/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >> "$STUB_LOG"
case "$1" in
  list-units) for f in "$STUB_UNITS"/*; do [ -f "$f" ] && echo "${f##*/} loaded active running x"; done ;;
  show)       cat "$STUB_UNITS/${*: -1}" 2>/dev/null || echo 0 ;;
  restart)    [ "${2:-}" = "${STUB_FAIL_RESTART:-}" ] && exit 1 ;;
esac
exit 0
STUB
chmod +x "$T/bin/systemctl"; export PATH="$T/bin:$PATH"

maps() { local pid=$1; shift; mkdir -p "$HR/proc/$pid"; printf '%s\n' "$@" > "$HR/proc/$pid/maps"; }
run() { env HOST_ROOT="$HR" "$@" bash "$ROOT/bin/deferred-restart.sh" app > "$T/out.txt" 2>&1; echo $? > "$T/rc.txt"; }
rc() { cat "$T/rc.txt"; }
restarted() { grep -qx "systemctl restart $1" "$STUB_LOG"; }

echo "1. no list: nothing to do"
: > "$STUB_LOG"; run
check "exit 0"                    [ "$(rc)" = 0 ]
check "nothing restarted"         bash -c '! grep -q restart "$1"' _ "$STUB_LOG"

echo "2. a stale deferred unit is restarted; a current one, an undeferred one, and shared memory are not"
echo postgresql > "$HR/etc/site-deploy/deferred-restart/app"
echo 101 > "$STUB_UNITS/postgresql@17-main.service"
echo 102 > "$STUB_UNITS/postgresql@16-old.service"
echo 103 > "$STUB_UNITS/app.service"
echo 0   > "$STUB_UNITS/postgresql-gone.service"
maps 101 "7f00-7f01 r-xp 00000000 fd:01 123 /usr/lib/x86_64-linux-gnu/libssl.so.3 (deleted)"
maps 102 "7f00-7f01 r-xp 00000000 fd:01 124 /usr/lib/x86_64-linux-gnu/libssl.so.3" \
         "7f02-7f03 rw-s 00000000 00:01 125 /dev/zero (deleted)" \
         "7f04-7f05 rw-s 00000000 00:01 126 /SYSV0052e2c1 (deleted)"
maps 103 "7f00-7f01 r-xp 00000000 fd:01 123 /usr/lib/x86_64-linux-gnu/libssl.so.3 (deleted)"
: > "$STUB_LOG"; run
check "exit 0"                    [ "$(rc)" = 0 ]
check "stale postgresql restarted" restarted postgresql@17-main.service
check "current one left alone (shared memory is not staleness)" bash -c '! grep -q "restart postgresql@16-old" "$1"' _ "$STUB_LOG"
check "undeferred unit left alone" bash -c '! grep -q "restart app.service" "$1"' _ "$STUB_LOG"
check "no main process: skipped"  bash -c '! grep -q "restart postgresql-gone" "$1"' _ "$STUB_LOG"

echo "3. a replaced executable counts too"
maps 102 "55aa-55ab r-xp 00000000 fd:01 127 /usr/lib/postgresql/16/bin/postgres (deleted)"
: > "$STUB_LOG"; run
check "restarted"                 restarted postgresql@16-old.service

echo "4. a failed restart fails the run, after trying the rest"
: > "$STUB_LOG"; run STUB_FAIL_RESTART=postgresql@16-old.service
check "exit 1"                    [ "$(rc)" = 1 ]
check "the other one still restarted" restarted postgresql@17-main.service
check "said so"                   grep -q "restart FAILED" "$T/out.txt"

echo "5. a tampered list is re-checked against the toolkit's allow-list"
echo 104 > "$STUB_UNITS/ssh.service"
maps 104 "7f00-7f01 r-xp 00000000 fd:01 123 /usr/lib/x86_64-linux-gnu/libssl.so.3 (deleted)"
printf 'pg\n*\nssh\npostgres\n' > "$HR/etc/site-deploy/deferred-restart/app"
: > "$STUB_LOG"; run
check "exit 0"                    [ "$(rc)" = 0 ]
check "nothing restarted"         bash -c '! grep -q restart "$1"' _ "$STUB_LOG"

echo
if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; else echo "all checks passed"; fi
exit $((fails > 0))
