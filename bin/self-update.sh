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

git merge --ff-only --quiet "$REMOTE" || { log "fast-forward failed (${LOCAL:0:9} -> ${REMOTE:0:9}) — manual fix"; exit 1; }
log "updated ${LOCAL:0:9} -> ${REMOTE:0:9} (origin/$REF)"
