#!/usr/bin/env bash
# Scenario tests for bin/site-tree.sh: root's own, verified copy of a site's
# code (issue #31 part 2). The service user's checkout is the ATTACKER here:
# every scenario that tampers with it asserts the tampering never reaches the
# tree root reads from.
#
# No root, no network: HOST_ROOT= points every path at a sandbox, the origin is
# a local bare repo, and SITE_TREE_PROTOCOLS=file lets git use it (production
# allows https and ssh only).
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); [ -s "$T/out.txt" ] && sed 's/^/         | /' "$T/out.txt" | tail -8; }
check() { local desc=$1; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }

T=$(mktemp -d); export T
if [ -n "${KEEP_SANDBOX:-}" ]; then trap 'echo "sandbox kept at $T"' EXIT; else trap 'rm -rf "$T"' EXIT; fi
HR="$T/root"; export HR
mkdir -p "$HR/srv" "$HR/etc/site-deploy/origin" "$HR/var/lib"
ln -s "$ROOT" "$HR/srv/site-deploy"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

ORIGIN="$T/origin.git"; WORK="$T/work"; SRV="$HR/srv/site"
git init -q --bare "$ORIGIN"
git init -q "$WORK"
( cd "$WORK" || exit 1
  mkdir -p deploy apps/foo/deploy
  echo v1 > app.py
  printf '#!/usr/bin/env bash\necho "HOOK RAN from $PWD tree=${SITE_TREE:-} srv=${SRV:-}" >> "$T/hook.log"\n' > deploy/converge.sh
  printf '#!/usr/bin/env bash\necho "FOO HOOK RAN from $PWD" >> "$T/hook.log"\n' > apps/foo/deploy/converge.sh
  chmod +x deploy/converge.sh apps/foo/deploy/converge.sh
  git add -A && git commit -qm v1 && git branch -M master && git remote add origin "$ORIGIN" && git push -q origin master )
git clone -q "$ORIGIN" "$SRV"
printf 'url=file://%s\n' "$ORIGIN" > "$HR/etc/site-deploy/origin/site"

sha() { git -C "$WORK" rev-parse "${1:-HEAD}"; }
advance() { ( cd "$WORK" || exit 1; echo "$1" >> app.py; git commit -qam "$1"; git push -q origin master ); }
run() { env HOST_ROOT="$HR" SITE_TREE_PROTOCOLS=file bash "$ROOT/bin/site-tree.sh" "$@" > "$T/out.txt" 2>&1; echo $? > "$T/rc.txt"; }
rc() { cat "$T/rc.txt"; }
TREES="$HR/var/lib/site-deploy-root/tree/site"

echo "1. pin a commit on master: verified, exported, current"
S1=$(sha)
run pin site "$S1"
check "exit 0"                         [ "$(rc)" = 0 ]
check "prints the tree path"           grep -qx "$TREES/$S1" "$T/out.txt"
check "content exported"               grep -qx v1 "$TREES/$S1/app.py"
check "exec bit kept"                  [ -x "$TREES/$S1/deploy/converge.sh" ]
check "current points at it"           [ "$(readlink "$TREES/current")" = "$S1" ]
check "no .git in the tree"            [ ! -e "$TREES/$S1/.git" ]
run path site
check "path prints current"            grep -qx "$TREES/current" "$T/out.txt"

echo "2. a commit only on ANOTHER origin branch is refused (merge access is master)"
( cd "$WORK" || exit 1; git checkout -q -b feature; echo f >> app.py; git commit -qam feature; git push -q origin feature; git checkout -q master )
run pin site "$(sha feature)"
check "exit 1"                         [ "$(rc)" = 1 ]
check "said not on master"             grep -qi "not on master" "$T/out.txt"
check "current unchanged"              [ "$(readlink "$TREES/current")" = "$S1" ]

echo "3. a commit made ON the box (the service user's checkout) is refused"
( cd "$SRV" || exit 1; echo evil > evil.txt; git add -A; git commit -qm evil )
run pin site "$(git -C "$SRV" rev-parse HEAD)"
check "exit 1"                         [ "$(rc)" = 1 ]
check "no tree for it"                 [ ! -e "$TREES/$(git -C "$SRV" rev-parse HEAD)" ]

echo "4. a redirected remote.origin.url in the checkout changes nothing: root uses the pinned URL"
EVIL="$T/evil.git"; git clone -q --bare "$SRV" "$EVIL"            # its master carries the evil commit
git -C "$SRV" remote set-url origin "file://$EVIL"
run pin site "$(git -C "$SRV" rev-parse HEAD)"
check "still refused"                  [ "$(rc)" = 1 ]
git -C "$SRV" reset -q --hard origin/master 2>/dev/null; git -C "$SRV" remote set-url origin "$ORIGIN"

echo "5. a malformed sha or extra arguments are refused before anything runs"
for bad in HEAD "-x" 1234abc "$S1 extra"; do
  # shellcheck disable=SC2086
  run pin site $bad
  check "refused: $bad"                [ "$(rc)" = 2 ]
done
run pin "../site" "$S1"
check "refused: a site name that is a path" [ "$(rc)" = 2 ]

echo "6. no pinned origin: refuses, naming the file"
mv "$HR/etc/site-deploy/origin/site" "$T/origin.bak"
advance v2; run pin site "$(sha)"
check "exit 1"                         [ "$(rc)" = 1 ]
check "named the file"                 grep -q "etc/site-deploy/origin/site" "$T/out.txt"
mv "$T/origin.bak" "$HR/etc/site-deploy/origin/site"

echo "7. a pinned URL of a command-running transport is refused"
cp "$HR/etc/site-deploy/origin/site" "$T/origin.bak"
printf 'url=ext::sh -c touch%%20%s/pwned\n' "$T" > "$HR/etc/site-deploy/origin/site"
run pin site "$(sha)"
check "exit 1"                         [ "$(rc)" = 1 ]
check "nothing ran"                    [ ! -e "$T/pwned" ]
cp "$T/origin.bak" "$HR/etc/site-deploy/origin/site"

echo "8. a newer master commit fetches; an already-verified one needs no network"
S2=$(sha); run pin site "$S2"
check "exit 0"                         [ "$(rc)" = 0 ]
check "current moved"                  [ "$(readlink "$TREES/current")" = "$S2" ]
mv "$ORIGIN" "$T/origin.away"
run pin site "$S2"
check "cached: still pins with origin gone" [ "$(rc)" = 0 ]
mv "$T/origin.away" "$ORIGIN"

echo "8b. forward only: an OLDER master commit is refused, current does not move back"
run pin site "$S1"
check "exit 1"                         [ "$(rc)" = 1 ]
check "said never moves backwards"     grep -q "never moves backwards" "$T/out.txt"
check "current still S2"               [ "$(readlink "$TREES/current")" = "$S2" ]
run converge site "$S1"
check "converge of an older commit refused too" [ "$(rc)" = 1 ]

echo "9. only current + previous trees are kept"
advance v3; S3=$(sha); run pin site "$S3"
advance v4; S4=$(sha); run pin site "$S4"
check "current is v4"                  [ "$(readlink "$TREES/current")" = "$S4" ]
check "previous kept"                  [ -d "$TREES/$S3" ]
check "older pruned"                   [ ! -e "$TREES/$S2" ]

echo "9b. two concurrent pins of one new commit leave one clean tree, never one nested in the other"
advance v4b; S4B=$(sha)
for _ in 1 2 3; do env HOST_ROOT="$HR" SITE_TREE_PROTOCOLS=file bash "$ROOT/bin/site-tree.sh" pin site "$S4B" >/dev/null 2>&1 & done; wait
check "exported once"                  grep -qx v1 <(head -1 "$TREES/$S4B/app.py")
check "nothing nested inside it"       bash -c '! find "'"$TREES/$S4B"'" -mindepth 1 -maxdepth 1 -name ".tmp.*" | grep -q .'
check "no temp dirs left"              bash -c '! ls -d "'"$TREES"'"/.tmp.* >/dev/null 2>&1'
S4=$S4B

echo "9c. a pin waits for a running converge hook: the tree in use is never pruned under it"
( cd "$WORK" || exit 1
  printf '#!/usr/bin/env bash
sleep 2
[ -f "$PWD/app.py" ] && echo "TREE INTACT" >> "$T/hook.log"
' > deploy/converge.sh
  git add -A; git commit -qm "slow hook"; git push -q origin master )
SLOW=$(sha); : > "$T/hook.log"
env HOST_ROOT="$HR" SITE_TREE_PROTOCOLS=file bash "$ROOT/bin/site-tree.sh" converge site "$SLOW" >/dev/null 2>&1 &
cpid=$!; sleep 0.5
advance v4c; run pin site "$(sha)"; advance v4d; run pin site "$(sha)"   # would prune $SLOW
wait "$cpid"
check "the hook still saw its tree"    grep -q "TREE INTACT" "$T/hook.log"
( cd "$WORK" || exit 1
  printf '#!/usr/bin/env bash
echo "HOOK RAN from $PWD tree=${SITE_TREE:-} srv=${SRV:-}" >> "$T/hook.log"
' > deploy/converge.sh
  git add -A; git commit -qm "hook back"; git push -q origin master )
S4=$(sha); run pin site "$S4"

echo "9d. a daemon a hook leaves running never keeps the lock: the next pin is not blocked"
( cd "$WORK" || exit 1
  printf '#!/usr/bin/env bash\nsleep 20 &\necho $! > "$T/daemon.pid"\n' > deploy/converge.sh
  git add -A; git commit -qm "hook forks a daemon"; git push -q origin master )
run converge site "$(sha)"
advance v4e
start=$(date +%s)
env HOST_ROOT="$HR" SITE_TREE_PROTOCOLS=file SITE_TREE_LOCK_WAIT=10 bash "$ROOT/bin/site-tree.sh" pin site "$(sha)" > "$T/out.txt" 2>&1; echo $? > "$T/rc.txt"
check "next pin succeeded"             [ "$(rc)" = 0 ]
check "without waiting on the daemon"  [ $(( $(date +%s) - start )) -lt 8 ]
kill "$(cat "$T/daemon.pid")" 2>/dev/null || true
( cd "$WORK" || exit 1
  printf '#!/usr/bin/env bash\necho "HOOK RAN from $PWD tree=${SITE_TREE:-} srv=${SRV:-}" >> "$T/hook.log"\n' > deploy/converge.sh
  git add -A; git commit -qm "hook back again"; git push -q origin master )
S4=$(sha); run pin site "$S4"

echo "10. converge runs the TREE's hook, never the checkout's"
printf '#!/usr/bin/env bash\ntouch "$T/checkout-hook-ran"\n' > "$SRV/deploy/converge.sh"   # tampered on the box
: > "$T/hook.log"
run converge site "$S4"
check "exit 0"                         [ "$(rc)" = 0 ]
check "the tree's hook ran"            grep -q "HOOK RAN from $TREES/$S4 " "$T/hook.log"
check "with SITE_TREE and SRV"         grep -q "tree=$TREES/$S4 srv=/srv/site" "$T/hook.log"
check "the checkout's never did"       [ ! -e "$T/checkout-hook-ran" ]
git -C "$SRV" checkout -q -- deploy/converge.sh

echo "11. converge <site> <sha> <app> runs that workspace app's own hook from the tree"
( cd "$WORK" || exit 1; printf '[workspace]\napps_dir = "apps"\n' > deploy/site.toml; git add -A; git commit -qm ws; git push -q origin master )
S5=$(sha); : > "$T/hook.log"
run converge site "$S5" foo
check "exit 0"                         [ "$(rc)" = 0 ]
check "foo's hook ran from the tree"   grep -q "FOO HOOK RAN from $TREES/$S5/apps/foo" "$T/hook.log"
run path site foo
check "path site foo is foo's dir in current" grep -qx "$TREES/current/apps/foo" "$T/out.txt"
run path site nosuch
check "path of an app the tree lacks refuses" [ "$(rc)" = 1 ]
run converge site "$S5" ../foo
check "an app name that is a path is refused" [ "$(rc)" = 2 ]
run converge site "$S5" nosuch
check "an app the tree lacks is refused"  [ "$(rc)" = 1 ]

echo "12. no hook: the [converge] engine runs against the tree, not the checkout"
( cd "$WORK" || exit 1; git rm -q deploy/converge.sh; git commit -qm "no hook"; git push -q origin master )
printf '[converge]\nensure_active = ["evil"]\n' >> "$SRV/deploy/site.toml" 2>/dev/null || printf '[converge]\nensure_active = ["evil"]\n' > "$SRV/deploy/site.toml"
S6=$(sha)
run converge site "$S6"
check "engine ran"                     grep -q "converge\[site\]" "$T/out.txt"
check "it never saw the checkout's table" bash -c '! grep -q evil "$T/out.txt"'

echo "13. a hook present but not executable in the tree is a failure, not a skip"
( cd "$WORK" || exit 1; printf 'echo x\n' > deploy/converge.sh; git add -A; git commit -qm "not exec"; git push -q origin master )
run converge site "$(sha)"
check "exit 1"                         [ "$(rc)" = 1 ]
check "said not executable"            grep -qi "not executable" "$T/out.txt"

echo "14. use: a NON-converging site's root consumers get master's head as \`tip\`, and \`current\` never moves"
( cd "$WORK" || exit 1; printf '[deploy]\nreload = "reload"\n' > deploy/site.toml; chmod +x deploy/converge.sh; git add -A; git commit -qm "no converge"; git push -q origin master )
S7=$(sha); run pin site "$S7"; cur_before=$(readlink "$TREES/current")
advance v14; HEAD14=$(sha)
run use site
check "exit 0"                         [ "$(rc)" = 0 ]
check "answers the tip link"           grep -qx "$TREES/tip" "$T/out.txt"
check "tip is master's head"           [ "$(readlink "$TREES/tip")" = "$HEAD14" ]
check "current untouched"              [ "$(readlink "$TREES/current")" = "$cur_before" ]
run pin site "$HEAD14"
check "a later deploy still pins forward" [ "$(rc)" = 0 ]

echo "15. use: a CONVERGING site's root consumers get what the poller converged, not master's head"
( cd "$WORK" || exit 1; printf '[deploy]\nconverge = true\n' > deploy/site.toml; git add -A; git commit -qm "converge on"; git push -q origin master )
S8=$(sha); run pin site "$S8"; advance v15
run use site
check "answers current"                grep -qx "$TREES/current" "$T/out.txt"
check "which is the converged commit"  [ "$(readlink "$TREES/current")" = "$S8" ]

echo "16. use: master unreachable keeps the tip already exported, and says so"
( cd "$WORK" || exit 1; printf '[deploy]\nreload = "reload"\n' > deploy/site.toml; git add -A; git commit -qm "off again"; git push -q origin master )
run pin site "$(sha)"; run use site; tip_before=$(readlink "$TREES/tip")
mv "$ORIGIN" "$T/origin.away"
run use site
check "exit 0"                         [ "$(rc)" = 0 ]
check "same tip"                       [ "$(readlink "$TREES/tip")" = "$tip_before" ]
check "said it could not fetch"        grep -q "could not fetch master" "$T/out.txt"
mv "$T/origin.away" "$ORIGIN"

echo "17. origin: pinned once from the checkout, then never re-read from it"
mv "$HR/etc/site-deploy/origin/site" "$T/origin-file.bak"
git -C "$SRV" remote set-url origin "file://$ORIGIN"
run origin site
check "exit 0"                         [ "$(rc)" = 0 ]
check "pinned from the checkout"       grep -qx "url=file://$ORIGIN" "$HR/etc/site-deploy/origin/site"
check "said PINNED"                    grep -q "PINNED the origin" "$T/out.txt"
git -C "$SRV" remote set-url origin "file://$T/evil.git"
run origin site
check "later checkout URL ignored"     grep -qx "url=file://$ORIGIN" "$HR/etc/site-deploy/origin/site"
check "and silent"                     [ ! -s "$T/out.txt" ]
rm "$HR/etc/site-deploy/origin/site"; git -C "$SRV" remote set-url origin "ext::sh -c id"
run origin site
check "a command transport is never pinned" bash -c '[ "$(cat "'"$T"'/rc.txt")" = 1 ] && [ ! -e "'"$HR"'/etc/site-deploy/origin/site" ]'
mv "$T/origin-file.bak" "$HR/etc/site-deploy/origin/site"; git -C "$SRV" remote set-url origin "$ORIGIN"

echo "18. a hook that reads /srv/<site> BY NAME still sees only the verified tree (private mount namespace)"
# Production runs as root with `unshare --mount`; here a user namespace stands
# in for root. Skipped (said so) where the kernel refuses unprivileged ones.
if unshare -r --mount --propagation private -- true 2>/dev/null; then
  ( cd "$WORK" || exit 1
    printf '[deploy]\nconverge = true\n' > deploy/site.toml
    printf '#!/usr/bin/env bash\ncat /srv/site/app.py > "$T/hook-saw" 2>/dev/null || cat "%s/srv/site/app.py" > "$T/hook-saw"\ntouch "%s/srv/site/hook-wrote" 2>/dev/null || echo RO >> "$T/hook-saw"\n' "$HR" "$HR" > deploy/converge.sh
    chmod +x deploy/converge.sh; git add -A; git commit -qm "hook reads by name"; git push -q origin master )
  NS=$(sha); rm -f "$T/hook-saw"
  echo "TAMPERED ON THE BOX" > "$SRV/app.py"
  export SITE_TREE_UNSHARE="unshare -r --mount --propagation private"
  run converge site "$NS"
  unset SITE_TREE_UNSHARE
  check "exit 0"                         [ "$(rc)" = 0 ]
  check "the hook read the tree's app.py" bash -c '! grep -q TAMPERED "'"$T"'/hook-saw" && grep -q "^v1" "'"$T"'/hook-saw"'
  check "and could not write into it"    grep -q RO "$T/hook-saw"
  check "outside the hook, the checkout is untouched" grep -q TAMPERED "$SRV/app.py"
  git -C "$SRV" checkout -q -- app.py
else
  echo "  skip (unprivileged user namespaces unavailable here; production uses root's unshare --mount)"
fi

echo
if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; else echo "all checks passed"; fi
exit $((fails > 0))
