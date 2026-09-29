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

# systemd-run: records its arguments and runs the command it was given, with
# its stdin, the way `--pipe --wait` does -- minus the uid switch itself,
# which only a real systemd can do (the arguments are asserted instead).
cat > "$T/bin/systemd-run" <<'STUB'
#!/usr/bin/env bash
echo "systemd-run $*" >> "$STUB_LOG"
while [ $# -gt 0 ]; do
  case $1 in -p) shift 2 ;; -*) shift ;; *) break ;; esac
done
exec "$@"
STUB

cat > "$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$STUB_LOG"
exit 0
STUB
chmod +x "$T/bin"/*
export PATH="$T/bin:$PATH"

# The producer root runs comes from root's verified tree (bin/site-tree.sh,
# its own suite); a sandbox tree stands in for it here. The checkout keeps a
# copy too, as a real one would, which is what makes "a producer in the
# checkout but no tree" a distinguishable, loud case.
TREE="$HR/var/lib/site-deploy-root/tree/app/0123456789abcdef0123456789abcdef01234567"
mkdir -p "$TREE/deploy"; ln -sfn "${TREE##*/}" "${TREE%/*}/current"
printf '[deploy]\nconverge = true\n' > "$TREE/deploy/site.toml"   # a converging site: `use` answers `current`
cat > "$TREE/deploy/backup-producer.sh" <<'PRODUCER'
#!/usr/bin/env bash
[ -n "${STUB_PRODUCER_FAIL:-}" ] && { echo "pg_dump: error: the-producer-reason" >&2; exit 1; }
[ -n "${STUB_PRODUCER_WARN:-}" ] && echo "pg_dump: warning: the-producer-warning" >&2
[ -n "${STUB_PRODUCER_EMPTY:-}" ] && exit 0
printf 'the-backup-content'
PRODUCER
chmod +x "$TREE/deploy/backup-producer.sh"
cp "$TREE/deploy/backup-producer.sh" "$HR/srv/app/deploy/backup-producer.sh"
MARKER="$HR/var/lib/site-deploy-root/backup/app/backup-last-success"

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
mv "$HR/srv/app/deploy/backup-producer.sh" "$T/producer.bak"; mv "$TREE/deploy/backup-producer.sh" "$T/tree-producer.bak"
reset_log; run
check "exit 0"                 [ "$(rc)" = 0 ]
check "said nothing to back up" grep -qi "nothing to back up" "$T/out.txt"
check "no age/rclone calls"    [ ! -s "$STUB_LOG" ]
mv "$T/producer.bak" "$HR/srv/app/deploy/backup-producer.sh"; mv "$T/tree-producer.bak" "$TREE/deploy/backup-producer.sh"

echo "1b. root runs the TREE's producer, never the checkout's (issue #31)"
printf '#!/usr/bin/env bash\ntouch "%s/checkout-producer-ran"; printf tampered\n' "$T" > "$HR/srv/app/deploy/backup-producer.sh"
reset_log; run
check "exit 0"                 [ "$(rc)" = 0 ]
check "the checkout's never ran" [ ! -e "$T/checkout-producer-ran" ]
check "the tree's content shipped" bash -c 'f=$(find "'"$STUB_REMOTE"'" -name "app-*.age" | head -1); [ "$(cat "$f")" = the-backup-content ]'
cp "$TREE/deploy/backup-producer.sh" "$HR/srv/app/deploy/backup-producer.sh"; rm -rf "${STUB_REMOTE:?}"/* "$MARKER"

echo "1c. a producer in the checkout but no verified tree: a loud failure, never a fallback"
mv "${TREE%/*}/current" "$T/current.bak"
reset_log; run
check "exit 1"                 [ "$(rc)" = 1 ]
check "said no verified tree"  grep -q "no verified tree" "$T/out.txt"
check "nothing shipped"        [ -z "$(find "$STUB_REMOTE" -type f)" ]
mv "$T/current.bak" "${TREE%/*}/current"

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
check "marker written"                  [ -f "$MARKER" ]
check "said OK"                         grep -q "OK" "$T/out.txt"

echo "5. the uploaded object round-trips to the exact producer content"
reset_log; run
f=$(find "$STUB_REMOTE" -name "app-*.age" | head -1)
check "content matches"        [ "$(cat "$f")" = "the-backup-content" ]

echo "6. the producer fails: refuses, no upload, no marker"
rm -rf "${STUB_REMOTE:?}"/*; rm -f "$MARKER"
reset_log; run STUB_PRODUCER_FAIL=1
check "exit 1"                 [ "$(rc)" = 1 ]
check "no upload"              [ -z "$(remote_files)" ]
check "no marker"              [ ! -f "$MARKER" ]

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
check "no marker"              [ ! -f "$MARKER" ]

echo "10. a round-trip mismatch (corrupted upload) is caught, not silently accepted"
reset_log; run STUB_CORRUPT_UPLOAD=1
check "exit 1"                          [ "$(rc)" = 1 ]
check "said mismatch"                   grep -qi "mismatch" "$T/out.txt"
check "marker NOT written on mismatch"  [ ! -f "$MARKER" ]

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

echo "14. backup_user (issue #44): the producer runs as that user via systemd-run, not as root"
rm -rf "${STUB_REMOTE:?}"/*; rm -f "$MARKER"
cp "$TREE/deploy/site.toml" "$T/tree-site.toml.bak"
printf '[deploy]\nconverge = true\nbackup_user = "nobody"\n' > "$TREE/deploy/site.toml"
reset_log; run
check "exit 0"                          [ "$(rc)" = 0 ]
check "through systemd-run"             called "systemd-run"
check "as that user"                    grep -qE "systemd-run .*--uid=nobody( |$)" "$STUB_LOG"
check "in a sandbox"                    grep -qE "systemd-run .*-p NoNewPrivileges=yes" "$STUB_LOG"
check "never handed root's environment" bash -c '! grep -qE "systemd-run .*(-E|--setenv|BACKUP_)" "$STUB_LOG"'
check "the producer's content shipped"  bash -c 'f=$(find "$STUB_REMOTE" -name "app-*.age" | head -1); [ "$(cat "$f")" = the-backup-content ]'
reset_log; run STUB_PRODUCER_FAIL=1
check "its failure is the run's"        [ "$(rc)" = 1 ]
check "said the producer failed"        grep -q "backup-producer.sh failed" "$T/out.txt"
check "with its own stderr, via a file" grep -q "backup-producer.sh failed: .*the-producer-reason" "$T/out.txt"
reset_log; run STUB_PRODUCER_FAIL=1 HEALTHCHECKS_BACKUP_URL=https://hc.example/b1
check "the reason reaches the /fail ping" grep -q "hc.example/b1/fail.*the-producer-reason\|the-producer-reason.*hc.example/b1/fail" "$STUB_LOG"
reset_log; run STUB_PRODUCER_WARN=1
check "a warning on success is logged"  grep -q "producer: pg_dump: warning: the-producer-warning" "$T/out.txt"
check "and kept out of the backup"      bash -c 'f=$(find "$STUB_REMOTE" -name "app-*.age" | sort | tail -1); [ "$(cat "$f")" = the-backup-content ]'

echo "15. no backup_user: the producer runs directly, as today"
cp "$T/tree-site.toml.bak" "$TREE/deploy/site.toml"
reset_log; run
check "exit 0"                          [ "$(rc)" = 0 ]
check "no systemd-run"                  not_called "systemd-run"

echo "16. backup_user is read from the verified tree, never the checkout"
printf '[deploy]\nbackup_user = "nobody"\n' > "$HR/srv/app/deploy/site.toml"
reset_log; run
check "exit 0"                          [ "$(rc)" = 0 ]
check "the checkout's knob is ignored"  not_called "systemd-run"
rm -f "$HR/srv/app/deploy/site.toml"

echo "17. a backup_user that is not a plain name of a user on this box is refused"
for bad in "no-such-user-4x2q" "-u" "root x" "../x" ""$'\n'"nobody"; do
  printf '[deploy]\nconverge = true\nbackup_user = %s\n' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$bad")" > "$TREE/deploy/site.toml"
  rm -rf "${STUB_REMOTE:?}"/*
  reset_log; run
  check "refused $(printf %q "$bad"): exit 1"     [ "$(rc)" = 1 ]
  check "refused $(printf %q "$bad"): said so"    grep -q "REFUSED backup_user" "$T/out.txt"
  check "refused $(printf %q "$bad"): no run"     not_called "systemd-run"
  check "refused $(printf %q "$bad"): nothing shipped" [ -z "$(remote_files)" ]
done

echo "18. an unreadable site.toml in the tree fails loudly, never falls back to root"
printf '[deploy]\nbackup_user = "nobody\n' > "$TREE/deploy/site.toml"
rm -rf "${STUB_REMOTE:?}"/*
reset_log; run
check "exit 1"                          [ "$(rc)" = 1 ]
check "the producer never ran as root"  not_called "age "
check "nothing shipped"                 [ -z "$(remote_files)" ]

echo "19. a producer run as backup_user must be a bash script (it is fed to bash on stdin)"
printf '[deploy]\nconverge = true\nbackup_user = "nobody"\n' > "$TREE/deploy/site.toml"
cp "$TREE/deploy/backup-producer.sh" "$T/tree-producer.bak"
printf '#!/usr/bin/env python3\nprint("x")\n' > "$TREE/deploy/backup-producer.sh"
reset_log; run
check "exit 1"                          [ "$(rc)" = 1 ]
check "said why"                        grep -q "bash" "$T/out.txt"
check "no run"                          not_called "systemd-run"
cp "$T/tree-producer.bak" "$TREE/deploy/backup-producer.sh"
cp "$T/tree-site.toml.bak" "$TREE/deploy/site.toml"

echo
if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; else echo "all checks passed"; fi
exit $((fails > 0))
