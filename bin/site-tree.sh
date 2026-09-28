#!/usr/bin/env bash
# site-tree.sh — root's own, verified copy of a site's code (issue #31 part 2).
#
#   site-tree.sh pin <site> <sha>              verify <sha> is on master, export
#                                              it, point `current` at it; prints
#                                              the tree's path
#   site-tree.sh path <site> [<app>]           prints the `current` tree (or that
#                                              workspace app's dir in it); exit 1
#                                              if there is none
#   site-tree.sh converge <site> <sha> [<app>] pin, then run that app's converge
#                                              FROM THE TREE (its deploy/converge.sh
#                                              hook, else the [converge] engine)
#   site-tree.sh use <site> [<app>]            for root's other consumers (backup,
#                                              cf-converge): the converged `current`
#                                              tree on a converging site, else a
#                                              `tip` tree refreshed to master's head
#   site-tree.sh origin <site> [--admin]       pin the origin URL from the checkout:
#                                              once, when this lands (self-update),
#                                              or by an admin (install.sh)
#
# The service user's sudo grant (host-converge.sh) is `converge <site> *` and
# nothing else; `pin`, `use`, `origin` and `path` are for root's own units.
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

usage() { echo "usage: site-tree.sh pin <site> <sha> | path <site> [<app>] | converge <site> <sha> [<app>] | use <site> [<app>] | origin <site> [--admin]" >&2; exit 2; }
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

# https://..., ssh://..., or scp-like user@host:path. Never a leading '-' (an
# option to git), never a transport:: form (ext:: runs a command), no
# whitespace. file:// only when the protocol list allows it (tests).
url_ok() {   # <url>
  local u=$1 auth
  [[ $u =~ [[:space:]] || $u == *::* || -z $u ]] && return 1
  # No credentials in the URL: the pin is a world-readable file and is logged.
  # https takes none at all (a user part there is a token); ssh a user only.
  auth=${u#*://}; auth=${auth%%/*}
  case $u in https://*) [[ $auth == *@* ]] && return 1 ;; ssh://*) [[ ${auth%@*} == *:* && $auth == *@* ]] && return 1 ;; esac
  case $u in
    https://*|ssh://*) return 0 ;;
    file://*) [[ :$PROTOCOLS: == *:file:* ]] ;;
    *) [[ $u =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+:[^:[:space:]][^[:space:]]*$ ]] ;;
  esac
}

# The pinned origin, which root alone writes. Never taken from the checkout
# here: this runs under the service user's `converge` grant, and a first-use
# pin reachable from there would let whoever controls the checkout choose the
# URL (and so the code root runs). See `origin` below for how it gets written.
read_origin() {
  local f="$ORIGIN_DIR/$site"
  [ -r "$f" ] || refuse "no pinned origin at $f; an admin writes url=<clone URL> there (install.sh does it), plus key=<ssh identity> for a private repo over ssh"
  URL=$(sed -n 's/^url=//p' "$f" | tail -1)
  KEY=$(sed -n 's/^key=//p' "$f" | tail -1)
  url_ok "$URL" || refuse "pinned url in $f is not a credential-free https, ssh or user@host:path URL; refusing"
  if [ -n "$KEY" ] && ! [[ $KEY =~ ^/[A-Za-z0-9._/-]+$ ]]; then
    refuse "pinned key=$(printf '%q' "$KEY") is not an absolute path; refusing"
  fi
}

# `origin <site> [--admin]`: write the pin from the checkout's remote.origin.url
# (read with `git config --file`, which honours no include and runs nothing).
# Never granted to the service user. Without --admin it is a ONE-TIME window:
# the first attempt, made by root's own self-update when this toolkit version
# lands (a moment the service user cannot choose), closes it whether it pinned
# or not, so a checkout URL changed later can never be pinned by waiting.
# --admin is install.sh, run by a person who just cloned the checkout.
pin_origin() {   # [--admin]
  local f="$ORIGIN_DIR/$site" done="$STATE/origin-window/$site" url tmp
  [ -r "$f" ] && return 0
  if [ "${1:-}" != --admin ] && [ -e "$done" ]; then
    refuse "no pinned origin at $f, and the first-use window is closed; an admin writes url=<clone URL> there"
  fi
  mkdir -p "$STATE/origin-window" && : > "$done"
  url=$(env -i PATH=/usr/local/bin:/usr/bin:/bin GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
          git config --file "$ROOT/srv/$site/.git/config" --get remote.origin.url 2>/dev/null || true)
  url_ok "$url" || refuse "cannot pin an origin for $site: the checkout's remote.origin.url is not a credential-free https or ssh URL; an admin writes url=<clone URL> to $f"
  tmp=$(mktemp) && printf 'url=%s\n' "$url" > "$tmp" \
    && install -d -m0755 "$ORIGIN_DIR" && install -m0644 "$tmp" "$f" \
    || { rm -f "$tmp"; refuse "could not write $f"; }
  rm -f "$tmp"
  say "PINNED the origin root fetches $site from: $url (taken from the checkout; check it in $f)" >&2
  case $url in https://*) ;; *) say "WARNING $url is ssh: unless the repo is readable anonymously, add key=<ssh identity readable by root> to $f" >&2 ;; esac
}

on_master() {   # <sha>
  git_root --git-dir="$MIRROR" cat-file -e "$1^{commit}" 2>/dev/null \
    && git_root --git-dir="$MIRROR" merge-base --is-ancestor "$1" refs/heads/master 2>/dev/null
}

# One lock per site. pin holds it exclusively (fetch, export, repoint,
# prune); converge holds it SHARED while its hook runs, so a concurrent pin
# can neither place a half-built tree nor prune the one in use.
# Bounded, never a hang: a lock held past the timeout is a stuck converge,
# which must fail this deploy loudly rather than stall every later one. And
# fd 9 is closed for everything this script runs, so a daemon a hook starts
# can never keep the lock.
LOCK_WAIT="${SITE_TREE_LOCK_WAIT:-600}"
lock() {   # <-s|-x>
  mkdir -p "$TREES" && exec 9>"$TREES/.lock" && flock -w "$LOCK_WAIT" "$1" 9 \
    || refuse "could not lock $TREES within ${LOCK_WAIT}s (a converge still running?)"
}

prepare() {   # origin, dirs, the exclusive lock, the mirror
  read_origin
  (umask 077; mkdir -p "$STATE/home" "$STATE/mirror" "$TREES")
  chmod 0755 "$STATE" "$STATE/tree" "$TREES" 2>/dev/null || true
  lock -x
  [ -d "$MIRROR" ] || git_root init -q --bare "$MIRROR" || refuse "could not create $MIRROR"
}
fetch_master() {
  git_root --git-dir="$MIRROR" fetch -q --no-tags "$URL" "+refs/heads/master:refs/heads/master" \
    || refuse "could not fetch master from the pinned origin $URL (credentials? see key= in $ORIGIN_DIR/$site)"
}
export_tree() {   # <sha>: $TREES/<sha>, exported once, placed atomically
  local sha=$1 tmp
  [ -d "$TREES/$sha" ] && return 0
  tmp=$(mktemp -d "$TREES/.tmp.XXXXXX") || refuse "could not create a temp tree"
  if ! git_root --git-dir="$MIRROR" archive "$sha" 9>&- | tar -x -C "$tmp"; then
    rm -rf "$tmp"; refuse "could not export ${sha:0:9}"
  fi
  chmod 0755 "$tmp"
  mv -T "$tmp" "$TREES/$sha" || { rm -rf "$tmp"; refuse "could not place $TREES/$sha"; }
}
repoint() {   # <link> <sha>: atomic, so readers see the old tree or the new one
  ln -sfn "$2" "$TREES/.$1.new" && mv -T "$TREES/.$1.new" "$TREES/$1" || refuse "could not repoint $TREES/$1"
}
# Keep exactly the trees `current`, `previous` and `tip` name: bookkeeping,
# not a guess from mtimes (tar stamps every file with its commit's time).
prune() {
  local d keep=" "
  for d in current previous tip; do keep+="$(readlink "$TREES/$d" 2>/dev/null) "; done
  for d in "$TREES"/*/; do
    d=${d%/}; d=${d##*/}
    [[ $d =~ ^[0-9a-f]{40}$ ]] || continue
    [[ $keep == *" $d "* ]] || rm -rf "${TREES:?}/$d"
  done
}

pin() {   # <sha> -> `current`; prints the tree dir
  local sha=$1 cur
  [[ $sha =~ ^[0-9a-f]{40}$ ]] || usage
  prepare
  if ! on_master "$sha"; then
    fetch_master
    on_master "$sha" || refuse "${sha:0:9} is not on master at $URL; root converges only merged commits"
  fi
  # Forward only. Deploys only ever fast-forward, so a sha OLDER than the
  # current tree is not a deploy: it would re-run an old hook (with whatever
  # bug it had) and roll `current` back. A rewritten master is an operator's
  # call: remove $TREES/current.
  cur=$(readlink "$TREES/current" 2>/dev/null || true)
  if [[ $cur =~ ^[0-9a-f]{40}$ ]] && [ "$cur" != "$sha" ] \
     && ! git_root --git-dir="$MIRROR" merge-base --is-ancestor "$cur" "$sha" 2>/dev/null; then
    refuse "${sha:0:9} is not a descendant of the current tree ${cur:0:9}; root never moves backwards (after a history rewrite, remove $TREES/current)"
  fi
  export_tree "$sha"
  [[ $cur =~ ^[0-9a-f]{40}$ ]] && [ "$cur" != "$sha" ] && repoint previous "$cur"
  repoint current "$sha"
  prune
  printf '%s\n' "$TREES/$sha"
}

# `tip`: master's head, for a site whose root consumers are not tied to a
# converged deploy. Never touches `current` (a converging site's deploys stay
# forward-only against what the POLLER converged). A fetch that fails keeps
# the tip already there, if any, and says so.
tip() {
  local sha
  prepare
  if ! ( fetch_master ) 2>/dev/null; then
    [ -d "$TREES/tip/" ] || fetch_master
    say "WARNING could not fetch master; using the tip already exported ($(readlink "$TREES/tip" | cut -c1-9))" >&2
    printf '%s\n' "$TREES/tip"; return 0
  fi
  sha=$(git_root --git-dir="$MIRROR" rev-parse --verify -q refs/heads/master) || refuse "the mirror has no master"
  export_tree "$sha"
  repoint tip "$sha"
  prune
  printf '%s\n' "$TREES/tip"
}

app_dir_in() {   # <tree> <app> -> that app's directory inside the tree
  local apps_dir
  # shellcheck disable=SC1091
  . "$SELF/lib/workspace.sh"
  apps_dir=$(ws_apps_dir "$1")
  [[ $apps_dir =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*(/[A-Za-z0-9_][A-Za-z0-9_.-]*)*$ ]] && [[ /$apps_dir/ != */../* ]] \
    || refuse "[workspace] apps_dir $(printf '%q' "$apps_dir") is not a plain relative path"
  [ -d "$1/$apps_dir/$2" ] || refuse "the tree has no $apps_dir/$2"
  printf '%s\n' "$1/$apps_dir/$2"
}

case $cmd in
  pin)
    [ $# -eq 3 ] || usage
    pin "$3" ;;
  path)
    [ $# -eq 2 ] || [ $# -eq 3 ] || usage
    app=${3:-}
    [ -z "$app" ] || name_ok "$app" || usage
    [ -L "$TREES/current" ] && [ -d "$TREES/current/" ] || refuse "no verified tree yet (nothing pinned)"
    if [ -n "$app" ]; then app_dir_in "$TREES/current" "$app"; else printf '%s\n' "$TREES/current"; fi ;;
  origin)
    [ $# -eq 2 ] || { [ $# -eq 3 ] && [ "$3" = --admin ]; } || usage
    pin_origin "${3:-}" ;;
  use)
    [ $# -eq 2 ] || [ $# -eq 3 ] || usage
    app=${3:-}
    [ -z "$app" ] || name_ok "$app" || usage
    # A converging site's consumers use what the poller converged; any other
    # site's use master's head (merged code either way).
    base=""
    if [ -d "$TREES/current/" ]; then
      case $(python3 "$SELF/bin/site-config.py" "$TREES/current/deploy/site.toml" 2>/dev/null \
               | sed -n "s/^export DEPLOY_CONVERGE=//p" | tail -1 | tr -d "'\"") in
        True|true|1) base="$TREES/current" ;;
      esac
    fi
    [ -n "$base" ] || base=$(tip) || exit 1
    exec 9>&-
    if [ -n "$app" ]; then app_dir_in "$base" "$app"; else printf '%s\n' "$base"; fi ;;
  converge)
    [ $# -eq 3 ] || [ $# -eq 4 ] || usage
    app=${4:-}
    [ -z "$app" ] || name_ok "$app" || usage
    tree=$(pin "$3") || exit 1
    lock -s
    if [ -n "$app" ]; then appdir=$(app_dir_in "$tree" "$app") || exit 1; else appdir=$tree; fi
    hook="$appdir/deploy/converge.sh"
    export SITE_TREE="$tree" SRV="/srv/$site"
    if [ -x "$hook" ]; then
      # A hook may well read its files from /srv/<site> by name (webbsite's
      # does: REPO=/srv/webbsite), and that path is the service user's. So it
      # runs in a private mount namespace where /srv/<site> IS the verified
      # tree, bound read-only over the checkout for this process alone. Root
      # without that isolation refuses: never a fallback to the checkout.
      if [ "$(id -u)" = 0 ] || [ -n "${SITE_TREE_UNSHARE:-}" ]; then
        ${SITE_TREE_UNSHARE:-unshare --mount --propagation private} -- bash -c '
          mount --bind "$1" "$2" && mount -o remount,bind,ro "$2" || exit 97
          cd "$3" && exec "$4"' _ "$tree" "$ROOT/srv/$site" "${appdir/#$tree/$ROOT/srv/$site}" "${hook/#$tree/$ROOT/srv/$site}" \
          9>&- </dev/null
        rc=$?
        [ "$rc" = 97 ] && refuse "could not bind the verified tree over /srv/$site for the hook; refusing to run it against the checkout"
        [ "$rc" = 0 ] || refuse "deploy/converge.sh failed"
      else
        ( cd "$appdir" && "$hook" 9>&- ) || refuse "deploy/converge.sh failed"
      fi
    elif [ -e "$hook" ]; then
      refuse "deploy/converge.sh is in the tree but not executable (a forgotten chmod +x, not 'no hook')"
    else
      SITE_TREE="$tree" "$SELF/bin/converge.sh" "${app:-$site}" --tree "$appdir" 9>&- || exit 1
    fi ;;
  *) usage ;;
esac
