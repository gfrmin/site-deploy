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
# UNLESS the app's site.toml sets `backup_user` (issue #44): state guarded by
# IDENTITY rather than file permissions -- PostgreSQL peer auth, which only
# the `postgres` OS user passes -- is out of root's reach, and this unit's
# NoNewPrivileges=yes forbids the producer switching user itself. systemd
# does the switch instead: the producer runs in a transient unit as that
# user, in its own sandbox, with none of this unit's environment (so not the
# backup-env credential either).
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
# Root's own store: a stamp written as root into /var/lib/<app> (possibly the
# app's own StateDirectory=) would follow whatever symlink the app put there.
STATE_DIR="${BACKUP_STATE_DIR:-$ROOT/var/lib/site-deploy-root/backup/$APP}"
# shellcheck disable=SC1091
. "$SELF/lib/hc.sh"
# shellcheck disable=SC1091
. "$SELF/lib/workspace.sh"

HC_URL="${HEALTHCHECKS_BACKUP_URL:-}"
log() { echo "backup[$APP]: $*"; }
fail() {
  log "FAILED: $*"
  hc_ping "$HC_URL" /fail "backup[$APP]: $*"
  exit 1
}

# The producer runs as ROOT, so it comes from root's verified tree of the
# deployed commit (bin/site-tree.sh), never from the checkout the service user
# can write (issue #31). A producer in the checkout with no tree to take it
# from is a backup that cannot run: loud, never a fallback.
site=$(ws_site_of "$ROOT" "$APP")
# stdout is the tree's path; anything site-tree.sh says goes to our stderr.
tree_why=$(mktemp); trap 'rm -f "$tree_why"' EXIT
if [ "$site" = "$APP" ]; then tree=$("$SELF/bin/site-tree.sh" use "$site" 2>"$tree_why")
else tree=$("$SELF/bin/site-tree.sh" use "$site" "$APP" 2>"$tree_why"); fi || {
  tree=$(cat "$tree_why")
  [ -e "$SRV/deploy/backup-producer.sh" ] \
    && fail "no verified tree of $APP's code to take backup-producer.sh from ($tree)"
  log "no deploy/backup-producer.sh; nothing to back up"; exit 0
}
cat "$tree_why" >&2
PRODUCER="$tree/deploy/backup-producer.sh"
[ -x "$PRODUCER" ] || { log "no deploy/backup-producer.sh in the deployed tree; nothing to back up"; exit 0; }

# From the TREE's site.toml, the same verified copy the producer comes from.
# No site.toml is no knob; an unreadable one is a failure, never "run as root".
producer_user=$(python3 -c 'import os, sys, tomllib
if not os.path.exists(sys.argv[1]): sys.exit(0)
deploy = tomllib.load(open(sys.argv[1], "rb")).get("deploy", {})
if not isinstance(deploy, dict): sys.exit(1)
sys.stdout.write(str(deploy.get("backup_user", "")))' "$tree/deploy/site.toml" 2>/dev/null) \
  || fail "deploy/site.toml in the deployed tree is unreadable"
if [ -n "$producer_user" ]; then
  { [[ $producer_user =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && id -u "$producer_user" >/dev/null 2>&1; } \
    || fail "REFUSED backup_user $(printf '%q' "$producer_user"): not the plain name of a user on this box"
  # Handed over on stdin: the tree is root's, so the user cannot open the file.
  [[ $(head -1 "$PRODUCER") =~ ^#!(/usr)?/bin/(env\ )?bash([[:space:]]|$) ]] \
    || fail "backup_user is set, so deploy/backup-producer.sh must be a bash script (#!/usr/bin/env bash): bash runs it as $producer_user"
fi
# The producer's transient unit outlives this run unless stopped: killing
# systemd-run does not stop the unit it started, and the producer's stdout
# is a file, not a pipe that would close under it. So a run killed by its
# TimeoutStartSec stops the unit on the way out rather than leaving it
# running as the target user into the next run.
producer_unit=""
stop_producer() { [ -z "$producer_unit" ] || systemctl stop "$producer_unit" 2>/dev/null || true; }
trap 'exit 143' TERM INT
run_producer() {
  if [ -z "$producer_user" ]; then "$PRODUCER"; return; fi
  local rc
  producer_unit="site-backup-producer-$APP-$$"
  # The same hardening as site-backup@.service. The script arrives on stdin
  # and is read ONCE; it then runs with stdin on /dev/null, so a command in
  # it that reads stdin sees EOF instead of eating the rest of the script.
  systemd-run --quiet --wait --pipe --collect --unit="$producer_unit" \
    --uid="$producer_user" --gid="$(id -g "$producer_user")" \
    -p Nice=19 -p OOMScoreAdjust=500 \
    -p NoNewPrivileges=yes -p ProtectSystem=strict -p ProtectHome=yes \
    -p PrivateTmp=yes -p PrivateDevices=yes -p ProtectKernelTunables=yes \
    -p ProtectKernelModules=yes -p ProtectControlGroups=yes \
    -p "RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX" -p RestrictNamespaces=yes \
    -p LockPersonality=yes -p SystemCallArchitectures=native -p ProtectClock=yes \
    /bin/bash -c 'script=$(cat) && exec /bin/bash -c "$script" backup-producer.sh </dev/null' \
    < "$PRODUCER"
  rc=$?
  producer_unit=""   # finished (and --collect'ed): nothing left to stop
  return $rc
}

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
trap 'stop_producer; rm -rf "$WORK" "$tree_why"' EXIT
plain="$WORK/plain"
cipher="$WORK/backup.age"

# The producer's stderr goes to a FILE, then into the log and the /fail ping:
# nested under systemd-run --pipe, its output to the unit's journal stream
# was seen to stop after the first line (issue #44), which would leave a
# failed pg_dump as a bare "failed" with its reason lost.
perr="$WORK/producer.err"
run_producer > "$plain" 2> "$perr" \
  || fail "deploy/backup-producer.sh failed: $(tail -c 1000 "$perr" | tr '\n' ' ')"
[ -s "$perr" ] && sed 's/^/producer: /' "$perr" >&2
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

install -d -m0700 "$STATE_DIR"
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
