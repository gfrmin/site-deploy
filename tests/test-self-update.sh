#!/usr/bin/env bash
# Scenario tests for bin/self-update.sh — the root oneshot that keeps
# /srv/site-deploy on the toolkit's tested ref.
#
# Same shape as test-auto-deploy.sh: a throwaway bare origin stands in for
# GitHub, runs continue from each other's state, every guard is checked by
# mutation. No network, no root, no systemd.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); }
check() { local desc=$1; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
ORIGIN="$T/origin.git"; WORK="$T/work"; SELF="$T/srv/site-deploy"
git init -q --bare "$ORIGIN"
git clone -q "$ORIGIN" "$WORK" 2>/dev/null
( cd "$WORK" || exit 1; echo v1 > VERSION; git add -A; git commit -qm v1; git branch -M master
  git push -q origin master; git push -q origin master:refs/heads/ci-green )
git clone -q "$ORIGIN" "$SELF" 2>/dev/null

push_master() { ( cd "$WORK" || exit 1; echo "$1" > VERSION; git add -A; git commit -qm "$1"; git push -q origin master ); }
green_to_master() { ( cd "$WORK" || exit 1; git push -q origin master:refs/heads/ci-green ); }
at() { git -C "$SELF" rev-parse @; }
origin_ref() { git -C "$WORK" rev-parse "origin/$1" 2>/dev/null || git -C "$WORK" rev-parse "$1"; }

run_update() {
  env SITE_DEPLOY_DIR="$SELF" "$@" bash "$ROOT/bin/self-update.sh" > "$T/out.txt" 2>&1
  echo $? > "$T/rc.txt"
}
rc() { cat "$T/rc.txt"; }
out() { cat "$T/out.txt"; }

echo "1. up to date -> silent no-op"
run_update
check "exit 0"            [ "$(rc)" = 0 ]
check "printed nothing"   [ -z "$(out)" ]

echo "2. master moved but ci-green did not -> stays put (nothing tested to take)"
push_master v2; run_update
check "exit 0"                    [ "$(rc)" = 0 ]
check "still at v1"               [ "$(cat "$SELF/VERSION")" = v1 ]
check "printed nothing"           [ -z "$(out)" ]

echo "3. ci-green advances -> fast-forwards onto it, says so"
green_to_master; run_update
check "exit 0"                    [ "$(rc)" = 0 ]
check "now at v2"                 [ "$(cat "$SELF/VERSION")" = v2 ]
check "logged the update"         grep -q "updated" "$T/out.txt"

echo "4. the ref is missing -> refuses loudly and keeps what it has"
( cd "$WORK" || exit 1; git push -q origin --delete ci-green )
push_master v3; run_update
check "exit 1"                    [ "$(rc)" = 1 ]
check "still at v2"               [ "$(cat "$SELF/VERSION")" = v2 ]
check "said REFUSING"             grep -q "REFUSING" "$T/out.txt"

echo "5. SITE_DEPLOY_REF=master bypasses the gate (documented escape hatch)"
run_update SITE_DEPLOY_REF=master
check "exit 0"                    [ "$(rc)" = 0 ]
check "now at v3"                 [ "$(cat "$SELF/VERSION")" = v3 ]

echo "6. a transient fetch failure is a retry, not a failed unit"
git -C "$SELF" remote set-url origin "$T/nowhere.git"
run_update SITE_DEPLOY_REF=master
check "exit 0"                    [ "$(rc)" = 0 ]
check "said fetch failed"         grep -qi "fetch failed" "$T/out.txt"
git -C "$SELF" remote set-url origin "$ORIGIN"

echo "7. a locally modified toolkit is never merged over: refuses, names the drift"
( cd "$WORK" || exit 1; git push -q origin master:refs/heads/ci-green )
echo hacked >> "$SELF/VERSION"
push_master v4; green_to_master; run_update
check "exit 1"                    [ "$(rc)" = 1 ]
check "kept the local edit"       grep -q hacked "$SELF/VERSION"
check "named the drift"           grep -qi "modified" "$T/out.txt"
git -C "$SELF" checkout -q -- VERSION

echo "8. clean again -> takes the pending update"
run_update
check "exit 0"                    [ "$(rc)" = 0 ]
check "now at v4"                 [ "$(cat "$SELF/VERSION")" = v4 ]

echo
if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; else echo "all checks passed"; fi
exit $((fails > 0))
