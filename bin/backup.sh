#!/usr/bin/env bash
# backup.sh <app> — encrypt the app's own backup stream and ship it off-box,
# verified by round trip, pruned to a fixed count. Root.
#
# Opt-in by the PRESENCE of deploy/backup-producer.sh in the app's own repo:
# the app declares WHAT to back up (a pg_dump, a sqlite3 .backup — anything
# that writes bytes to stdout and a clean exit); this script owns HOW
# (encrypt, ship, verify, prune, report). No backup-producer.sh means
# nothing to do, and is not an error — most apps have no runtime state that
# outlives a redeploy.
#
# WHY ROOT, and why the credential lives in root-only /etc/<app>/backup-env
# rather than the app's ordinary /etc/<app>/env: a write-capable
# object-storage credential must not sit in the environment of a
# public-facing gunicorn (the same reasoning as cf-converge's
# CF_CONFIG_TOKEN). The producer script itself also runs as root here, which
# is what lets it read state it does not own by construction (a WAL database
# under another user's directory, for instance) without a bespoke grant.
#
# WHY A ROUND TRIP, ported from renavon-monorepo's dataguru-backup-state.py:
# an upload that returned success is not a backup that can be read back. Its
# whole reason for existing was an off-box tarball that went 13 days stale
# while every layer read green — the upload had never actually been
# confirmed readable.
set -uo pipefail

APP=${1:?usage: backup.sh <app>}
ROOT="${HOST_ROOT:-}"
SELF="$ROOT/srv/site-deploy"
SRV="$ROOT/srv/$APP"
PRODUCER="$SRV/deploy/backup-producer.sh"
STATE_DIR="${BACKUP_STATE_DIR:-$ROOT/var/lib/$APP}"
# shellcheck disable=SC1091
. "$SELF/lib/hc.sh"

HC_URL="${HEALTHCHECKS_BACKUP_URL:-}"
log() { echo "backup[$APP]: $*"; }
fail() {
  log "FAILED: $*"
  hc_ping "$HC_URL" /fail "backup[$APP]: $*"
  exit 1
}

[ -x "$PRODUCER" ] || { log "no deploy/backup-producer.sh; nothing to back up"; exit 0; }

for var in BACKUP_AGE_RECIPIENT BACKUP_RCLONE_DEST; do
  [ -n "${!var:-}" ] || fail "deploy/backup-producer.sh exists but $var is not set in /etc/$APP/backup-env"
done
command -v age >/dev/null 2>&1 || fail "age is not installed; refusing to ship plaintext state"
command -v rclone >/dev/null 2>&1 || fail "rclone is not installed"

hc_ping "$HC_URL" /start "backup[$APP]: starting"

host="${BACKUP_HOST_NAME:-$(uname -n)}"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
destdir="${BACKUP_RCLONE_DEST%/}/$host"
dest="$destdir/$APP-$stamp.age"
keep="${BACKUP_KEEP_LAST:-14}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
plain="$WORK/plain"
cipher="$WORK/backup.age"

"$PRODUCER" > "$plain" || fail "deploy/backup-producer.sh failed"
[ -s "$plain" ] || fail "deploy/backup-producer.sh produced no output"

age --encrypt --recipient "$BACKUP_AGE_RECIPIENT" --output "$cipher" "$plain" \
  || fail "age encryption failed"
rm -f "$plain"   # the plaintext dies as soon as there is ciphertext
want=$(sha256sum "$cipher" | cut -d' ' -f1)

rclone rcat "$dest" < "$cipher" || fail "rclone rcat $dest failed"

# Verify by ROUND TRIP, before believing any of this happened: an upload that
# returned success is not a backup that can be read back.
got=$(rclone cat "$dest" | sha256sum | cut -d' ' -f1)
[ -n "$got" ] || fail "round-trip read of $dest failed"
if [ "$got" != "$want" ]; then
  fail "round trip mismatch ($want != $got) -- $dest may be corrupt"
fi

# Only now. Until the round trip proved the object readable, this local copy
# was the only thing standing between a claimed backup and no backup at all.
rm -f "$cipher"

install -d -m0755 "$STATE_DIR"
date -u +%Y-%m-%dT%H:%M:%SZ > "$STATE_DIR/backup-last-success"

# Prune to the newest $keep objects for THIS app. Names are timestamped, so
# lexical order is chronological order. Anchored at the start of the line so
# "app" cannot match "otherapp"'s objects sharing the same destination dir.
if [ "$keep" -gt 0 ]; then
  mapfile -t objs < <(rclone lsf "$destdir" 2>/dev/null | grep -E "^${APP}-[0-9TZ]+\.age\$" | sort)
  doomed=$(( ${#objs[@]} - keep ))
  if [ "$doomed" -gt 0 ]; then
    for ((i = 0; i < doomed; i++)); do
      rclone deletefile "$destdir/${objs[$i]}" || log "WARNING could not prune ${objs[$i]}"
    done
    log "pruned $doomed old backup(s)"
  fi
fi

log "OK $dest (sha256 ${want:0:12} verified)"
hc_ping "$HC_URL" "" "backup[$APP]: OK $dest"
exit 0
