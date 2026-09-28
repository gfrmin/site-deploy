#!/usr/bin/env bash
# site-tree.sh — root's own, verified copy of a site's code (issue #31 part 2).
#
#   site-tree.sh pin <site> <sha>              verify <sha> is on master, export
#                                              it, point `current` at it; prints
#                                              the tree's path
#   site-tree.sh path <site>                   prints the `current` tree; exit 1
#                                              if there is none
#   site-tree.sh converge <site> <sha> [<app>] pin, then run that app's converge
#                                              FROM THE TREE (its deploy/converge.sh
#                                              hook, else the [converge] engine)
#
# WHY. /srv/<site> is the service user's home: the checkout, its .git (config,
# refs, remote URL) and every file in it belong to whoever compromises the app.
# The README's bargain is that merge access may be root on a converging box and
# an app RCE must not be, so nothing root executes or applies may come from
# there. This is root's only source of app content:
#
#   * the origin URL is PINNED in root-owned /etc/site-deploy/origin/<site>
#     (url=..., optional key=... for ssh), never read from the checkout;
#   * root fetches it into its own bare mirror (/var/lib/site-deploy-root/mirror/)
#     through a hermetic transport: no system/global git config, root's own
#     known_hosts, only https and ssh (git's ext:: transport runs a command);
#   * a sha is accepted only if it is ON MASTER in that mirror: anything on
#     master is something a maintainer merged, which is the bargain exactly;
#   * it is exported with `git archive` into a root-owned tree, so no .git,
#     hook or config of any kind comes along.
#
# The service user can at worst break authentication (a loud DoS). It can
# never substitute content: the URL and the host key are root's.
#
# Exit: 0 ok, 1 refused or failed (with the reason), 2 usage.
set -uo pipefail

ROOT="${HOST_ROOT:-}"
SELF="$ROOT/srv/site-deploy"
# Root's own store. NOT under /var/lib/site-deploy/: each site's poller owns
# /var/lib/site-deploy/<site> (StateDirectory=), so a site named `mirror` or
# `tree` would own root's directories there.
STATE="$ROOT/var/lib/site-deploy-root"
ORIGIN_DIR="$ROOT/etc/site-deploy/origin"
PROTOCOLS="${SITE_TREE_PROTOCOLS:-https:ssh}"
KEEP=2   # trees kept: current + the one before it

usage() { echo "usage: site-tree.sh pin <site> <sha> | path <site> | converge <site> <sha> [<app>]" >&2; exit 2; }
name_ok() { [[ $1 =~ ^[a-z][a-z0-9_-]{0,31}$ ]]; }

cmd=${1:-}; site=${2:-}
name_ok "$site" || usage
say() { echo "site-tree[$site]: $*"; }
refuse() { say "$*" >&2; exit 1; }   # stderr: stdout is pin's tree path

MIRROR="$STATE/mirror/$site.git"
TREES="$STATE/tree/$site"

# A git that reads no config but the mirror's own and runs no command it was
# not asked to. HOME is root's own scratch dir, so ~/.gitconfig is not ours
# either; the ssh command ignores ~/.ssh/config and pins known_hosts.
git_root() {
  local ssh="ssh -F /dev/null -o IdentitiesOnly=yes -o BatchMode=yes"
  ssh="$ssh -o UserKnownHostsFile=$STATE/known_hosts -o StrictHostKeyChecking=accept-new"
  [ -n "${KEY:-}" ] && ssh="$ssh -i $KEY"
  env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$STATE/home" \
      GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
      GIT_ALLOW_PROTOCOL="$PROTOCOLS" GIT_SSH_COMMAND="$ssh" \
      git "$@"
}

read_origin() {
  local f="$ORIGIN_DIR/$site"
  [ -r "$f" ] || refuse "no pinned origin at $f (url=<clone URL>, optional key=<ssh identity>); refusing"
  URL=$(sed -n 's/^url=//p' "$f" | tail -1)
  KEY=$(sed -n 's/^key=//p' "$f" | tail -1)
  # https://..., ssh://..., or scp-like user@host:path. Never a leading '-'
  # (an option to git), never a transport:: form (ext:: runs a command), no
  # whitespace. file:// only when the protocol list allows it (tests).
  case $URL in
    https://*|ssh://*) ;;
    file://*) [[ :$PROTOCOLS: == *:file:* ]] || refuse "pinned url $URL: file:// is not allowed here" ;;
    *) [[ $URL =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+:[^:[:space:]][^[:space:]]*$ ]] \
         || refuse "pinned url $(printf '%q' "$URL") is not an https, ssh or user@host:path URL; refusing" ;;
  esac
  [[ $URL =~ [[:space:]] || $URL == *::* ]] && refuse "pinned url $(printf '%q' "$URL") is malformed; refusing"
  if [ -n "$KEY" ] && ! [[ $KEY =~ ^/[A-Za-z0-9._/-]+$ ]]; then
    refuse "pinned key=$(printf '%q' "$KEY") is not an absolute path; refusing"
  fi
}

on_master() {   # <sha>
  git_root --git-dir="$MIRROR" cat-file -e "$1^{commit}" 2>/dev/null \
    && git_root --git-dir="$MIRROR" merge-base --is-ancestor "$1" refs/heads/master 2>/dev/null
}

# One lock per site. pin holds it exclusively (fetch, export, repoint,
# prune); converge holds it SHARED while its hook runs, so a concurrent pin
# can neither place a half-built tree nor prune the one in use.
lock() {   # <-s|-x>
  mkdir -p "$TREES" && exec 9>"$TREES/.lock" && flock "$1" 9 || refuse "could not lock $TREES"
}

pin() {   # <sha> -> prints the tree dir
  local sha=$1 dir tmp cur
  [[ $sha =~ ^[0-9a-f]{40}$ ]] || usage
  read_origin
  (umask 077; mkdir -p "$STATE/home" "$STATE/mirror" "$TREES")
  chmod 0755 "$STATE" "$STATE/tree" "$TREES" 2>/dev/null || true
  lock -x
  [ -d "$MIRROR" ] || git_root init -q --bare "$MIRROR" || refuse "could not create $MIRROR"
  if ! on_master "$sha"; then
    git_root --git-dir="$MIRROR" fetch -q --no-tags "$URL" "+refs/heads/master:refs/heads/master" \
      || refuse "could not fetch master from the pinned origin $URL (credentials? see key= in $ORIGIN_DIR/$site)"
    on_master "$sha" || refuse "${sha:0:9} is not on master at $URL; root converges only merged commits"
  fi
  # Forward only. Deploys only ever fast-forward, so a sha OLDER than the
  # current tree is not a deploy: it would re-run an old hook (with whatever
  # bug it had) and roll `current` back for cf-converge and the backup. A
  # rewritten master is an operator's call: remove $TREES/current.
  cur=$(readlink "$TREES/current" 2>/dev/null || true)
  if [[ $cur =~ ^[0-9a-f]{40}$ ]] && [ "$cur" != "$sha" ] \
     && ! git_root --git-dir="$MIRROR" merge-base --is-ancestor "$cur" "$sha" 2>/dev/null; then
    refuse "${sha:0:9} is not a descendant of the current tree ${cur:0:9}; root never moves backwards (after a history rewrite, remove $TREES/current)"
  fi
  dir="$TREES/$sha"
  if [ ! -d "$dir" ]; then
    tmp=$(mktemp -d "$TREES/.tmp.XXXXXX") || refuse "could not create a temp tree"
    if ! git_root --git-dir="$MIRROR" archive "$sha" | tar -x -C "$tmp"; then
      rm -rf "$tmp"; refuse "could not export ${sha:0:9}"
    fi
    chmod 0755 "$tmp"
    mv -T "$tmp" "$dir" || { rm -rf "$tmp"; refuse "could not place $dir"; }
  fi
  # Atomic repoint: readers see the old tree or the new one, never neither.
  ln -sfn "$sha" "$TREES/.current.new" && mv -T "$TREES/.current.new" "$TREES/current" \
    || refuse "could not repoint $TREES/current"
  # Keep the newest $KEEP trees (current always among them).
  local d
  while IFS= read -r d; do
    [ "$(basename "$d")" = "$sha" ] || rm -rf "$d"
  done < <(find "$TREES" -mindepth 1 -maxdepth 1 -type d -regex '.*/[0-9a-f]\{40\}' -printf '%T@ %p\n' \
             | sort -rn | tail -n +$((KEEP + 1)) | cut -d' ' -f2-)
  printf '%s\n' "$dir"
}

case $cmd in
  pin)
    [ $# -eq 3 ] || usage
    pin "$3" ;;
  path)
    [ $# -eq 2 ] || usage
    [ -L "$TREES/current" ] && [ -d "$TREES/current/" ] || refuse "no verified tree yet (nothing pinned)"
    printf '%s\n' "$TREES/current" ;;
  converge)
    [ $# -eq 3 ] || [ $# -eq 4 ] || usage
    app=${4:-}
    [ -z "$app" ] || name_ok "$app" || usage
    tree=$(pin "$3") || exit 1
    lock -s
    # shellcheck disable=SC1091
    . "$SELF/lib/workspace.sh"
    if [ -n "$app" ]; then
      apps_dir=$(ws_apps_dir "$tree")
      [[ $apps_dir =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*(/[A-Za-z0-9_][A-Za-z0-9_.-]*)*$ ]] && [[ /$apps_dir/ != */../* ]] \
        || refuse "[workspace] apps_dir $(printf '%q' "$apps_dir") is not a plain relative path"
      appdir="$tree/$apps_dir/$app"
      [ -d "$appdir" ] || refuse "${3:0:9} has no $apps_dir/$app"
    else
      appdir=$tree
    fi
    hook="$appdir/deploy/converge.sh"
    if [ -x "$hook" ]; then
      ( cd "$appdir" && SITE_TREE="$tree" SRV="/srv/$site" "$hook" ) || refuse "deploy/converge.sh failed"
    elif [ -e "$hook" ]; then
      refuse "deploy/converge.sh is in the tree but not executable (a forgotten chmod +x, not 'no hook')"
    else
      SITE_TREE="$tree" "$SELF/bin/converge.sh" "${app:-$site}" --tree "$appdir" || exit 1
    fi ;;
  *) usage ;;
esac
