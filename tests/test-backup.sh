#!/usr/bin/env bash
# Scenario tests for bin/backup.sh: encrypt the app's own backup stream and
# ship it off-box, verified by round trip, pruned to a fixed count.
#
# HOST_ROOT= points every FILE path at a sandbox; `age`, `rclone` and `curl`
# are stubs on PATH. `rclone`'s stub is a tiny fake object store under
# $STUB_REMOTE (a plain directory tree keyed by the path after the remote's
# `:`), so `rcat`/`cat`/`lsf`/`deletefile` all agree with each other the way
# a real remote would.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); [ -s "$T/out.txt" ] && sed 's/^/         | /' "$T/out.txt" | tail -10; }
check() { local desc=$1; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }

T=$(mktemp -d); export T
if [ -n "${KEEP_SANDBOX:-}" ]; then trap 'echo "sandbox kept at $T"' EXIT; else trap 'rm -rf "$T"' EXIT; fi
export STUB_LOG="$T/calls.log"
HR="$T/root"; export HR
STUB_REMOTE="$T/remote"; export STUB_REMOTE
mkdir -p "$T/bin" "$HR/srv/app/deploy" "$HR/etc/app" "$STUB_REMOTE"
ln -s "$ROOT" "$HR/srv/site-deploy"

cat > "$T/bin/age" <<'STUB'
#!/usr/bin/env bash
echo "age $*" >> "$STUB_LOG"
[ -n "${STUB_AGE_FAIL:-}" ] && exit 1
out=""; prev=""
for a in "$@"; do
  [ "$prev" = "--output" ] && out="$a"
  prev="$a"; last="$a"
done
cp "$last" "$out"
STUB

cat > "$T/bin/rclone" <<'STUB'
#!/usr/bin/env bash
echo "rclone $*" >> "$STUB_LOG"
rel() { printf '%s' "${1#*:}"; }
case "$1" in
  rcat)
    [ -n "${STUB_RCAT_FAIL:-}" ] && exit 1
    p="$STUB_REMOTE/$(rel "$2")"
    mkdir -p "$(dirname "$p")"
    cat > "$p"
    if [ -n "${STUB_CORRUPT_UPLOAD:-}" ]; then printf 'x' >> "$p"; fi
    ;;
  cat)
    [ -n "${STUB_ROUNDTRIP_FAIL:-}" ] && exit 1
    p="$STUB_REMOTE/$(rel "$2")"
    [ -f "$p" ] && cat "$p" || exit 1
    ;;
  lsf)
    p="$STUB_REMOTE/$(rel "$2")"
    [ -d "$p" ] && (cd "$p" && ls -1) || true
    ;;
  deletefile)
    p="$STUB_REMOTE/$(rel "$2")"
    rm -f "$p"
    ;;
  *) exit 1 ;;
esac
STUB

cat > "$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$STUB_LOG"
exit 0
STUB
chmod +x "$T/bin"/*
export PATH="$T/bin:$PATH"

cat > "$HR/srv/app/deploy/backup-producer.sh" <<'PRODUCER'
#!/usr/bin/env bash
[ -n "${STUB_PRODUCER_FAIL:-}" ] && exit 1
[ -n "${STUB_PRODUCER_EMPTY:-}" ] && exit 0
printf 'the-backup-content'
PRODUCER
chmod +x "$HR/srv/app/deploy/backup-producer.sh"

reset_log() { : > "$STUB_LOG"; }
called() { grep -qF -e "$1" "$STUB_LOG"; }
not_called() { ! grep -qF -e "$1" "$STUB_LOG"; }
run() {
  env HOST_ROOT="$HR" BACKUP_AGE_RECIPIENT="${BACKUP_AGE_RECIPIENT:-age1recipient}" \
      BACKUP_RCLONE_DEST="${BACKUP_RCLONE_DEST:-fakeremote:bucket/backups}" "$@" \
      bash "$ROOT/bin/backup.sh" app > "$T/out.txt" 2>&1
  echo $? > "$T/rc.txt"
}
rc() { cat "$T/rc.txt"; }
remote_files() { find "$STUB_REMOTE" -type f | sort; }

echo "1. no deploy/backup-producer.sh: no-op, exit 0"
mv "$HR/srv/app/deploy/backup-producer.sh" "$T/producer.bak"
reset_log; run
check "exit 0"                 [ "$(rc)" = 0 ]
check "said nothing to back up" grep -qi "nothing to back up" "$T/out.txt"
check "no age/rclone calls"    [ ! -s "$STUB_LOG" ]
mv "$T/producer.bak" "$HR/srv/app/deploy/backup-producer.sh"

echo "2. backup-producer.sh exists but BACKUP_AGE_RECIPIENT unset: refuses loudly"
reset_log; run BACKUP_AGE_RECIPIENT=
check "exit 1"                 [ "$(rc)" = 1 ]
check "said so"                grep -q "BACKUP_AGE_RECIPIENT" "$T/out.txt"
check "no rclone"              not_called "rclone"

echo "3. BACKUP_RCLONE_DEST unset: refuses loudly"
reset_log; run BACKUP_RCLONE_DEST=
check "exit 1"                 [ "$(rc)" = 1 ]
check "said so"                grep -q "BACKUP_RCLONE_DEST" "$T/out.txt"

echo "4. a clean run: encrypts, uploads, verifies by round trip, writes the marker"
reset_log; run
check "exit 0"                          [ "$(rc)" = 0 ]
check "encrypted with the recipient"    called "age1recipient"
check "uploaded to host/app-stamp.age"  bash -c 'find "$STUB_REMOTE" -name "app-*.age" | grep -q .'
check "marker written"                  [ -f "$HR/var/lib/app/backup-last-success" ]
check "said OK"                         grep -q "OK" "$T/out.txt"

echo "5. the uploaded object round-trips to the exact producer content"
reset_log; run
f=$(find "$STUB_REMOTE" -name "app-*.age" | head -1)
check "content matches"        [ "$(cat "$f")" = "the-backup-content" ]

echo "6. the producer fails: refuses, no upload, no marker"
rm -rf "${STUB_REMOTE:?}"/*; rm -f "$HR/var/lib/app/backup-last-success"
reset_log; run STUB_PRODUCER_FAIL=1
check "exit 1"                 [ "$(rc)" = 1 ]
check "no upload"              [ -z "$(remote_files)" ]
check "no marker"              [ ! -f "$HR/var/lib/app/backup-last-success" ]

echo "7. the producer emits nothing: refused, not shipped as an empty backup"
reset_log; run STUB_PRODUCER_EMPTY=1
check "exit 1"                 [ "$(rc)" = 1 ]
check "said so"                grep -qi "no output" "$T/out.txt"
check "no upload"              [ -z "$(remote_files)" ]

echo "8. age itself fails: refuses, no upload"
reset_log; run STUB_AGE_FAIL=1
check "exit 1"                 [ "$(rc)" = 1 ]
check "no upload"              [ -z "$(remote_files)" ]

echo "9. the upload itself fails: refuses, no marker"
reset_log; run STUB_RCAT_FAIL=1
check "exit 1"                 [ "$(rc)" = 1 ]
check "no marker"              [ ! -f "$HR/var/lib/app/backup-last-success" ]

echo "10. a round-trip mismatch (corrupted upload) is caught, not silently accepted"
reset_log; run STUB_CORRUPT_UPLOAD=1
check "exit 1"                          [ "$(rc)" = 1 ]
check "said mismatch"                   grep -qi "mismatch" "$T/out.txt"
check "marker NOT written on mismatch"  [ ! -f "$HR/var/lib/app/backup-last-success" ]

echo "11. BACKUP_KEEP_LAST prunes the oldest objects for THIS app only"
rm -rf "${STUB_REMOTE:?}"/*
host=$(uname -n)
mkdir -p "$STUB_REMOTE/bucket/backups/$host"
for i in 1 2 3 4 5; do
  printf 'old' > "$STUB_REMOTE/bucket/backups/$host/app-2026010${i}T000000Z.age"
done
printf 'other-app-untouched' > "$STUB_REMOTE/bucket/backups/$host/otherapp-20260101T000000Z.age"
reset_log; run BACKUP_KEEP_LAST=2
check "exit 0"                          [ "$(rc)" = 0 ]
check "kept exactly BACKUP_KEEP_LAST=2" [ "$(find "$STUB_REMOTE/bucket/backups/$host" -maxdepth 1 -name 'app-*.age' | wc -l)" = 2 ]
check "kept the newest of the old ones" ls "$STUB_REMOTE/bucket/backups/$host" | grep -q app-20260105
check "pruned the oldest"               bash -c '! ls "'"$STUB_REMOTE/bucket/backups/$host"'" | grep -qE "^app-20260101"'
check "other app untouched"             [ -f "$STUB_REMOTE/bucket/backups/$host/otherapp-20260101T000000Z.age" ]

echo "12. HEALTHCHECKS_BACKUP_URL set: pinged /start then root on success"
reset_log; run HEALTHCHECKS_BACKUP_URL=https://hc.example/b1
check "pinged start"           called "https://hc.example/b1/start"
check "pinged root"            bash -c 'grep -q "https://hc.example/b1 " "$STUB_LOG" || grep -q "https://hc.example/b1$" "$STUB_LOG"'
check "not /fail"              not_called "/b1/fail"

echo "13. HEALTHCHECKS_BACKUP_URL set, a failure: pinged /fail with the reason"
reset_log; run HEALTHCHECKS_BACKUP_URL=https://hc.example/b1 STUB_RCAT_FAIL=1
check "pinged /fail"           called "https://hc.example/b1/fail"

echo
if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; else echo "all checks passed"; fi
exit $((fails > 0))
