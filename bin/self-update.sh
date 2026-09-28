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
LOCAL=$(git rev-parse @)
[ "$LOCAL" = "$REMOTE" ] && exit 0                 # current -> silent no-op

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
    exit 0   # ahead of the gate (deployed via the override); self-resolves when CI advances
  fi
  log "REFUSING TO UPDATE: $SELF has diverged from origin/$REF (${LOCAL:0:9} vs ${REMOTE:0:9}) — manual fix"
  exit 1
fi

# A commit already refused for breaking the Caddyfile (below) is not retried:
# merging it just to roll back again would put the broken snippet on disk for
# a moment every tick, and a Caddy restart in that moment would load it. A new
# commit on the ref retries.
refused="$(git rev-parse --git-dir)/site-deploy-caddy-refused"
if [ "$(cat "$refused" 2>/dev/null)" = "$REMOTE" ]; then
  log "REFUSING TO UPDATE: ${REMOTE:0:9} breaks the Caddyfile (refused earlier; see" \
      "above in this journal). Staying on ${LOCAL:0:9} until origin/$REF moves. Fix master."
  exit 1
fi

git merge --ff-only --quiet "$REMOTE" || { log "fast-forward failed (${LOCAL:0:9} -> ${REMOTE:0:9}) — manual fix"; exit 1; }
log "updated ${LOCAL:0:9} -> ${REMOTE:0:9} (origin/$REF)"

# The Caddy snippet (host/caddy/*.caddy) is imported by site Caddyfiles
# straight out of this checkout, so an update to it IS a change to every
# importing site's proxy config, one nothing else applies or checks: an app's
# converge only notices ITS Caddyfile changing. Unchecked, the edit sits
# unapplied until the next reload, and if it is broken that reload fails, or
# worse the next restart (Restart=always after an OOM kill) leaves Caddy DOWN.
#
# So: validate the live Caddyfile, as the unit's User= (validate opens every
# log file, and root would leave them root-owned), and reload on success. On
# failure, the question is whose fault it is. Roll back and validate again: if
# the OLD snippet passes, this update broke it, so stay on the old commit and
# refuse loudly every tick until master moves. If the old one fails too, the
# Caddyfile is broken on its own and holding the toolkit back fixes nothing,
# so go forward and say so. Both sides call the same validation, so a
# Caddyfile that imports no snippet can never cause a rollback.
git diff --quiet "$LOCAL" "$REMOTE" -- 'host/caddy/*.caddy' && exit 0
caddyfile=${CADDYFILE:-${HOST_ROOT:-}/etc/caddy/Caddyfile}
[ -f "$caddyfile" ] || exit 0
if [ -z "${CADDY_VALIDATE:-}" ]; then
  command -v caddy >/dev/null 2>&1 || exit 0
  caddy_user=$(systemctl show -p User --value caddy.service 2>/dev/null)
fi
caddy_validate() {   # the live Caddyfile against whatever is checked out now
  if [ -n "${CADDY_VALIDATE:-}" ]; then $CADDY_VALIDATE "$caddyfile"; return; fi
  # No User= means the daemon runs as root, so validating as root is faithful
  # (the same rule as validate_file in bin/converge.sh).
  if [ -n "${caddy_user:-}" ]; then
    runuser -u "$caddy_user" -- caddy validate --adapter caddyfile --config "$caddyfile"
  else
    caddy validate --adapter caddyfile --config "$caddyfile"
  fi
}
if ! why=$(caddy_validate 2>&1); then
  git reset --quiet --keep "$LOCAL" || { log "CADDY: $caddyfile fails validation after the update AND the rollback failed — manual fix"; exit 1; }
  if caddy_validate >/dev/null 2>&1; then
    echo "$REMOTE" > "$refused"
    log "REFUSING TO UPDATE: ${REMOTE:0:9} changes host/caddy/ and $caddyfile no longer" \
        "validates with it (it does with ${LOCAL:0:9}); rolled back, Caddy untouched. Fix master."
    printf '%s\n' "$why" | tail -5 | sed 's/^/site-deploy-update:   /'
    exit 1
  fi
  git merge --ff-only --quiet "$REMOTE" || { log "fast-forward failed (${LOCAL:0:9} -> ${REMOTE:0:9}) — manual fix"; exit 1; }
  log "CADDY: $caddyfile fails validation with the old snippet too, so not this update's" \
      "doing; NOT reloading. The next Caddy restart will fail until it is fixed."
  printf '%s\n' "$why" | tail -5 | sed 's/^/site-deploy-update:   /'
  exit 1
fi
${CADDY_ACTIVE:-systemctl is-active --quiet caddy.service} || exit 0
if ${CADDY_RELOAD:-systemctl reload caddy.service}; then
  log "reloaded Caddy: host/caddy/ changed and $caddyfile validates"
else
  log "CADDY: reload failed after a host/caddy/ change; Caddy is on its old config"; exit 1
fi
