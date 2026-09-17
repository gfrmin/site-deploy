#!/usr/bin/env bash
# Scenario tests for bin/env-check.sh: does the box carry the env NAMES the app
# declares in deploy/required-env.txt, and is the RUNNING app on that file?
#
# Fixtures only: ETC= points at a temp /etc/<app>, MANIFEST= at a temp
# manifest, `systemctl` is a stub on PATH and PROC_ROOT= a fake /proc. One
# property is asserted in EVERY case: a value never appears in the output.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); [ -s "$T/out.txt" ] && sed 's/^/         | /' "$T/out.txt" | tail -6; }
check() { local desc=$1; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }

T=$(mktemp -d); export T
trap 'rm -rf "$T"' EXIT
ETC="$T/etc"; MAN="$T/required-env.txt"; PROC="$T/proc"
mkdir -p "$ETC" "$T/bin" "$PROC/4242"
export STUB_UNIT_ACTIVE="${STUB_UNIT_ACTIVE:-}"
cat > "$T/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "is-active --quiet "*) [ -n "${STUB_UNIT_ACTIVE:-}" ] && exit 0; exit 3 ;;
  "show -p ExecMainStartTimestamp --value "*) echo "${STUB_UNIT_STARTED:-}" ;;
  "show -p MainPID --value "*) echo "${STUB_UNIT_PID:-4242}" ;;
esac
exit 0
STUB
chmod +x "$T/bin/systemctl"; export PATH="$T/bin:$PATH"

SECRET="s3cr3t-value-never-printed"
run() {   # run [VAR=val ...]
  env ETC="$ETC" MANIFEST="$MAN" PROC_ROOT="$PROC" "$@" bash "$ROOT/bin/env-check.sh" app > "$T/out.txt" 2>&1
  echo $? > "$T/rc.txt"
}
rc() { cat "$T/rc.txt"; }
no_leak() { ! grep -qF "$SECRET" "$T/out.txt"; }
says() { grep -qiF -e "$1" "$T/out.txt"; }

write_manifest() { cat > "$MAN"; }
write_manifest <<EOM
# file        NAME            grade           read by
env           DATABASE_URL    required        the app
env           SENTRY_DSN      blank-ok        opt-in error tracking
env           POOL_SIZE       optional        int() of it when present; blank = int("")
env           CF_TOKEN        required@fresh  cf-purge.sh re-reads the file each run
refresh-env   R2_KEY          required        the loader
EOM
cat > "$ETC/env" <<EOE
DATABASE_URL=$SECRET
SENTRY_DSN=
CF_TOKEN="tok"
EOE
printf 'R2_KEY=%s\n' "$SECRET" > "$ETC/refresh-env"

echo "1. a complete box is clean"
run
check "exit 0"                    [ "$(rc)" = 0 ]
check "said ok with counts"       says "ok (5 names across 2 files)"
check "no value leaked"           no_leak

echo "2. a required name absent -> exit 1, named as ABSENT"
sed -i '/^DATABASE_URL=/d' "$ETC/env"; run
check "exit 1"                    [ "$(rc)" = 1 ]
check "named it"                  says "DATABASE_URL"
check "said absent"               says "absent"
check "no value leaked"           no_leak
printf 'DATABASE_URL=%s\n' "$SECRET" >> "$ETC/env"

echo "3. a required name set BLANK is a different mistake, and says so"
sed -i "s/^DATABASE_URL=.*/DATABASE_URL=/" "$ETC/env"; run
check "exit 1"                    [ "$(rc)" = 1 ]
check "said empty value"          says "empty value"
sed -i "s/^DATABASE_URL=.*/DATABASE_URL=$SECRET/" "$ETC/env"

echo "4. an optional name: absent is a note, BLANK is a failure (blank is not absent)"
run
check "absent optional: exit 0"   [ "$(rc)" = 0 ]
check "but noted"                 says "POOL_SIZE"
echo "POOL_SIZE=" >> "$ETC/env"; run
check "blank optional: exit 1"    [ "$(rc)" = 1 ]
check "explained why"             says "not the same as leaving"
sed -i '/^POOL_SIZE=/d' "$ETC/env"

echo "5. blank-ok is never reported, blank or absent"
run
check "blank SENTRY_DSN: exit 0"  [ "$(rc)" = 0 ]
check "not mentioned"             bash -c '! grep -q SENTRY_DSN "$T/out.txt"'
sed -i '/^SENTRY_DSN=/d' "$ETC/env"; run
check "absent SENTRY_DSN: exit 0" [ "$(rc)" = 0 ]
echo "SENTRY_DSN=" >> "$ETC/env"

echo "6. a name on the box that the manifest does not declare -> exit 1"
echo "MYSTERY_KNOB=1" >> "$ETC/env"; run
check "exit 1"                    [ "$(rc)" = 1 ]
check "named it"                  says "MYSTERY_KNOB"
check "said undeclared"           says "not declared"
sed -i '/^MYSTERY_KNOB=/d' "$ETC/env"

echo "7. a declared file missing -> exit 1; anything unreadable -> exit 2 (BLIND is never clean)"
mv "$ETC/refresh-env" "$T/keep"; run
check "missing file: exit 1"      [ "$(rc)" = 1 ]
check "named the file"            says "refresh-env"
mv "$T/keep" "$ETC/refresh-env"
chmod 000 "$ETC/refresh-env"; run
check "unreadable env: exit 2"    [ "$(rc)" = 2 ]
check "said BLIND"                says "BLIND"
chmod 644 "$ETC/refresh-env"
run MANIFEST="$T/nope.txt"
check "unreadable manifest: exit 2" [ "$(rc)" = 2 ]

echo "8. a malformed manifest is exit 2, never a pass"
cp "$MAN" "$T/man.bak"
printf 'env FOO maybe reason\n' >> "$MAN"; run
check "bad grade: exit 2"         [ "$(rc)" = 2 ]
check "named the line"            says "maybe"
cp "$T/man.bak" "$MAN"; printf 'env DATABASE_URL required twice\n' >> "$MAN"; run
check "duplicate: exit 2"         [ "$(rc)" = 2 ]
cp "$T/man.bak" "$MAN"; printf 'env NO_REASON required\n' >> "$MAN"; run
check "no reason: exit 2"         [ "$(rc)" = 2 ]
cp "$T/man.bak" "$MAN"

echo "9. THE FILE IS NOT THE PROCESS: the running app is compared to what it booted with"
# The unit started an hour ago; the env file is newer.
STUB_UNIT_STARTED="$(date -d '-1 hour' '+%a %Y-%m-%d %H:%M:%S %Z')"
export STUB_UNIT_ACTIVE=1 STUB_UNIT_STARTED
environ() { printf '%s\0' "$@" > "$PROC/4242/environ"; }
environ "DATABASE_URL=$SECRET" "SENTRY_DSN=" "CF_TOKEN=tok" "HOME=/srv/app"
touch "$ETC/env"; run
check "booted values match: exit 0, silent" [ "$(rc)" = 0 ]
check "no value leaked"           no_leak
environ "DATABASE_URL=old-$SECRET" "SENTRY_DSN=" "CF_TOKEN=tok"; run
check "a serving var differs: exit 1" [ "$(rc)" = 1 ]
check "said NOT on this file"     says "NOT on this file"
check "named the var"             says "DATABASE_URL"
check "no value leaked"           no_leak
environ "DATABASE_URL=$SECRET" "SENTRY_DSN=" "CF_TOKEN=OLD"; run
check "only an @fresh var differs: exit 0" [ "$(rc)" = 0 ]
rm "$PROC/4242/environ"; run
check "environ unreadable: exit 1, mtime warning" [ "$(rc)" = 1 ]
check "said it could not compare" says "could not read"
environ "DATABASE_URL=$SECRET" "SENTRY_DSN=" "CF_TOKEN=tok"
export STUB_UNIT_ACTIVE=""; run
check "unit not running: nothing to compare, exit 0" [ "$(rc)" = 0 ]
export STUB_UNIT_STARTED=""; export STUB_UNIT_ACTIVE=1; run
check "never-started unit (empty timestamp) is not 'today at midnight': exit 0" [ "$(rc)" = 0 ]

echo
if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; else echo "all checks passed"; fi
exit $((fails > 0))
