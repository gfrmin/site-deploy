#!/usr/bin/env bash
# Keep /srv/site-deploy on the toolkit's TESTED ref. Run as root by
# site-deploy-update.timer; idempotent and silent when current.
#
# Until this existed the per-app poller pulled the toolkit itself, as the
# service user, from the tip of master, best-effort and silently. Three things
# were wrong with that, and one incident-shaped:
#
#   1. Merge to site-deploy master reached EVERY box within two minutes with
#      nothing in between. A broken commit here is a broken deploy fleet-wide,
#      so the toolkit now tracks `ci-green`, the ref .github/workflows/tests.yml
#      advances only after the suite passes on master. A box can only ever
#      fast-forward onto a commit whose whole suite was green.
#   2. The toolkit was owned by the service user, and root runs scripts out of
#      it (deploy/converge.sh, later host-converge). "Write access to the app's
#      uid is root" is a bargain worth making deliberately for the app repo; it
#      is not one worth making by accident for a directory the app never needs
#      to write. So /srv/site-deploy is root-owned and this runs as root.
#   3. `|| true` on the pull meant a toolkit that could not update — a drifted
#      checkout, a deleted ref, a wrong remote — said nothing, forever.
#
# No fallback to master if the ref is missing. A gate that opens when it cannot
# find its own lock is not a gate: an accidentally-deleted `ci-green`, or a fork
# where CI has never run, would silently restore ungated updates. Refusing keeps
# the last known-good toolkit running, which is the safe direction — but it can
# strand a box indefinitely, so it is logged loudly on EVERY tick, not once.
#
# Operator escape hatch: SITE_DEPLOY_REF=master in the unit's environment (or a
# drop-in) restores the ungated behaviour for the case this exists to survive —
# CI itself broken, or a toolkit fix that must ship before it can be green.
set -uo pipefail

SELF="${SITE_DEPLOY_DIR:-/srv/site-deploy}"
REF="${SITE_DEPLOY_REF:-ci-green}"
log() { echo "site-deploy-update: $*"; }

cd "$SELF" || { log "no toolkit checkout at $SELF"; exit 1; }

# Pin each site's origin for root's verified tree (bin/site-tree.sh), ONCE: the
# first tick of the toolkit version that has it, a moment the service user
# cannot choose. After that site-tree.sh keeps the window closed and only an
# admin writes a pin. Every tick, because it costs nothing once pinned; only a
# PINNED line or a first refusal is logged, never "window closed" again.
# A site is a /srv/<name> with an admin-created /etc/<name>: NOT "has a .git",
# which its owner controls (hiding .git would hold the window open until they
# chose to reveal it). The attempt is made, and the window closed, either way.
SRV_ROOT="${HOST_ROOT:-}/srv"
if [ -x "$SELF/bin/site-tree.sh" ]; then
  for d in "$SRV_ROOT"/*/; do
    d=${d%/}; s=${d##*/}
    { [ -L "$d" ] || [ "$s" = site-deploy ] || ! [[ $s =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || [ ! -d "${HOST_ROOT:-}/etc/$s" ]; } && continue
    out=$("$SELF/bin/site-tree.sh" origin "$s" 2>&1) && { [ -n "$out" ] && log "$out"; continue; }
    case $out in *"window is closed"*) ;; *) log "$out" ;; esac
  done
fi

# A transient fetch failure just retries next tick (exit 0, not failed) —
# the same rule as auto-deploy.sh, for the same reason: a flapping network
# must not turn into a red unit every two minutes.
#
# --prune is load-bearing. A ref deleted on the remote lives on as a stale
# refs/remotes/origin/<ref> locally until something prunes it, so without this
# a deleted ci-green would pass the existence check below forever and the gate
# would quietly keep "deploying" the last commit it ever pointed at.
git fetch --quiet --prune origin || { log "fetch failed (transient?); will retry next tick"; exit 0; }

if ! REMOTE=$(git rev-parse --verify --quiet "refs/remotes/origin/$REF"); then
  log "REFUSING TO UPDATE: origin/$REF does not exist, so there is no tested toolkit" \
      "commit to take. Keeping $(git rev-parse --short @). Fix CI, or set" \
      "SITE_DEPLOY_REF=master on site-deploy-update.service to bypass the gate."
  exit 1
fi
# The Caddy snippet (host/caddy/*.caddy) is imported by site Caddyfiles
# straight out of this checkout, so changing it IS a change to every importing
# site's proxy config, one nothing else applies or checks: an app's converge
# only notices ITS Caddyfile changing. Unchecked, an edit sits unapplied until
# the next reload, and if it is broken that reload fails, or worse the next
# restart (Restart=always after an OOM kill) leaves Caddy DOWN.
#
# So every tick, not only the one that updates, compares the snippet checked
# out with the one last validated and reloaded (a stamp in .git). Every way a
# snippet reaches this checkout converges: this updater, the override, a box
# ahead of the gate, install.sh, a pull by hand. A failure is retried and
# logged on EVERY tick until it clears, never once and then silence.
# Validation runs as the caddy unit's User= (it opens every log file, and root
# would leave them root-owned); no User= means the daemon is root, so root is
# faithful (the same rule as validate_file in bin/converge.sh).
GIT_DIR_ABS=$(git rev-parse --absolute-git-dir)
caddy_stamp="$GIT_DIR_ABS/site-deploy-caddy-applied"
refused="$GIT_DIR_ABS/site-deploy-caddy-refused"
caddyfile=${CADDYFILE:-${HOST_ROOT:-}/etc/caddy/Caddyfile}
caddy_wanted() {
  [ -f "$caddyfile" ] || return 1
  [ -n "${CADDY_VALIDATE:-}" ] || command -v caddy >/dev/null 2>&1
}
snippet_id() { git ls-tree -r HEAD -- host/caddy/ | grep '\.caddy$' | sha256sum | cut -c1-16; }
caddy_validate() {   # the live Caddyfile against whatever is checked out now
  if [ -n "${CADDY_VALIDATE:-}" ]; then $CADDY_VALIDATE "$caddyfile"; return; fi
  local user
  user=$(systemctl show -p User --value caddy.service 2>/dev/null)
  if [ -n "$user" ]; then
    runuser -u "$user" -- caddy validate --adapter caddyfile --config "$caddyfile"
  else
    caddy validate --adapter caddyfile --config "$caddyfile"
  fi
}
caddy_converge() {   # 0: applied or nothing to do; 1: does not validate; 2: reload failed. Says why.
  caddy_wanted || return 0
  local id why
  id=$(snippet_id)
  [ "$(cat "$caddy_stamp" 2>/dev/null)" = "$id" ] && return 0
  if ! why=$(caddy_validate 2>&1); then
    log "CADDY: $caddyfile does not validate with the snippet at $(git rev-parse --short @);" \
        "NOT reloading. Caddy keeps its old config, and its next restart will fail."
    printf '%s\n' "$why" | tail -5 | sed 's/^/site-deploy-update:   /'
    return 1
  fi
  if ${CADDY_ACTIVE:-systemctl is-active --quiet caddy.service}; then
    ${CADDY_RELOAD:-systemctl reload caddy.service} \
      || { log "CADDY: reload failed with a valid $caddyfile; Caddy is on its old config"; return 2; }
    log "reloaded Caddy: the host/caddy/ snippet changed and $caddyfile validates"
  fi
  echo "$id" > "$caddy_stamp"
}
# The refusal (below) is keyed to the commit AND the Caddyfile, so a change to
# either retries; `rm` of the file retries by hand.
refusal_key() { echo "$REMOTE $(sha256sum < "$caddyfile" 2>/dev/null | cut -c1-16)"; }

LOCAL=$(git rev-parse @)
if [ "$LOCAL" = "$REMOTE" ]; then caddy_converge; exit $?; fi   # current -> silent unless Caddy needs applying

# Never merge over a hand-edited toolkit. The tracked-file check comes BEFORE
# the ancestry check so the message names the actual problem: an operator
# debugging a script in place would otherwise see "fast-forward failed".
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  log "REFUSING TO UPDATE: tracked files are modified in $SELF (someone edited the" \
      "toolkit in place); commit or discard them. origin/$REF is at ${REMOTE:0:9}."
  git status --porcelain --untracked-files=no | sed 's/^/site-deploy-update:   /'
  exit 1
fi
if ! git merge-base --is-ancestor "$LOCAL" "$REMOTE"; then
  if git merge-base --is-ancestor "$REMOTE" "$LOCAL"; then
    caddy_converge; exit $?   # ahead of the gate (deployed via the override); self-resolves when CI advances
  fi
  log "REFUSING TO UPDATE: $SELF has diverged from origin/$REF (${LOCAL:0:9} vs ${REMOTE:0:9}) — manual fix"
  exit 1
fi

# A commit already refused for breaking this Caddyfile is not re-merged just to
# roll back again: that would put the broken snippet on disk for a moment every
# tick, and a Caddy restart in that moment would load it.
if caddy_wanted && [ "$(cat "$refused" 2>/dev/null)" = "$(refusal_key)" ]; then
  log "REFUSING TO UPDATE: ${REMOTE:0:9} breaks $caddyfile (refused earlier; the reason" \
      "is above in this journal). Staying on ${LOCAL:0:9} until origin/$REF moves or the" \
      "Caddyfile changes; rm $refused to retry now. Fix master."
  caddy_converge; exit 1
fi

git merge --ff-only --quiet "$REMOTE" || { log "fast-forward failed (${LOCAL:0:9} -> ${REMOTE:0:9}) — manual fix"; exit 1; }
log "updated ${LOCAL:0:9} -> ${REMOTE:0:9} (origin/$REF)"

caddy_converge; crc=$?
[ "$crc" = 0 ] && exit 0
[ "$crc" = 1 ] || exit 1   # a reload failure is not the snippet's fault; retried next tick
# It does not validate. Whose fault? If this update changed the snippet, roll back and
# validate the old one: if THAT passes, this update broke it, so stay on the
# old commit and refuse. Otherwise the Caddyfile is broken on its own and
# holding the toolkit back fixes nothing: stay forward (caddy_converge keeps
# saying so every tick). Both sides run the same validation, so a Caddyfile
# that imports no snippet can never cause a rollback.
git diff --quiet "$LOCAL" "$REMOTE" -- 'host/caddy/*.caddy' && exit 1
git reset --quiet --keep "$LOCAL" || { log "CADDY: rollback to ${LOCAL:0:9} failed — manual fix"; exit 1; }
if caddy_validate >/dev/null 2>&1; then
  refusal_key > "$refused"
  log "REFUSING TO UPDATE: ${REMOTE:0:9} changes host/caddy/ and $caddyfile no longer" \
      "validates with it (it does with ${LOCAL:0:9}); rolled back to ${LOCAL:0:9}. Fix master."
  caddy_converge; exit 1
fi
git merge --ff-only --quiet "$REMOTE" || { log "fast-forward failed (${LOCAL:0:9} -> ${REMOTE:0:9}) — manual fix"; exit 1; }
log "CADDY: $caddyfile fails with the old snippet too, so not this update's doing; staying on ${REMOTE:0:9}"
exit 1
