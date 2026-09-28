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

run_update() {   # Caddy stubbed off by default: never the dev box's real caddy or systemctl
  env SITE_DEPLOY_DIR="$SELF" CADDYFILE="$T/no-Caddyfile" CADDY_VALIDATE=false CADDY_ACTIVE=false \
      CADDY_RELOAD=false "$@" bash "$ROOT/bin/self-update.sh" > "$T/out.txt" 2>&1
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

echo "N. every tick asks site-tree.sh to pin each site checkout's origin (once; it keeps the window), and logs only news"
HR="$T/hostroot"; mkdir -p "$HR/srv/site" "$HR/etc/site" "$HR/srv/other" "$HR/srv/app.old/.git" "$HR/etc/app.old" "$SELF/bin"   # site: no .git yet, still asked
ln -s "$HR/srv/site" "$HR/srv/linked-app"
cat > "$SELF/bin/site-tree.sh" <<'STUB'
#!/usr/bin/env bash
echo "ORIGIN $*" >> "$T_LOG"
[ "$2" = site ] && [ ! -e "$T_LOG.pinned" ] && { : > "$T_LOG.pinned"; echo "site-tree[site]: PINNED the origin ..." >&2; }
exit 0
STUB
chmod +x "$SELF/bin/site-tree.sh"
export T_LOG="$T/origin.log"
run_update HOST_ROOT="$HR" T_LOG="$T_LOG"
check "asked for the site checkout"   grep -qx "ORIGIN origin site" "$T_LOG"
check "not for a dir with no /etc/<name>" bash -c '! grep -q "ORIGIN origin other" "'"$T_LOG"'"'
check "not for a name that is no site name" bash -c '! grep -q "app.old" "'"$T_LOG"'"'
check "not for an app symlink"        bash -c '! grep -q "linked-app" "'"$T_LOG"'"'
check "logged the PINNED line"        grep -q "PINNED" "$T/out.txt"
run_update HOST_ROOT="$HR" T_LOG="$T_LOG"
check "second tick: silent"           bash -c '! grep -q "PINNED" "'"$T"'/out.txt"'
rm -f "$SELF/bin/site-tree.sh"

echo "C. the host/caddy/*.caddy snippet: validated against the live Caddyfile and reloaded, every tick until applied"
# The validator stub fails if the snippet OR the Caddyfile says BROKEN, and
# logs each call with the snippet it saw, so each side of the rollback shows.
CV="$T/caddy.log"; CF="$T/Caddyfile"; echo "import $SELF/host/caddy/rp.caddy" > "$CF"
cat > "$T/validate" <<STUB
#!/usr/bin/env bash
echo "VALIDATE \$1 \$(cat "$SELF/host/caddy/rp.caddy" 2>/dev/null)" >> "$CV"
! grep -q BROKEN "\$1" "$SELF/host/caddy/rp.caddy" 2>/dev/null
STUB
printf '#!/usr/bin/env bash\necho RELOAD >> "%s"\n' "$CV" > "$T/reload"
chmod +x "$T/validate" "$T/reload"
STAMP="$SELF/.git/site-deploy-caddy-applied"; REFUSED="$SELF/.git/site-deploy-caddy-refused"
push_caddy() { ( cd "$WORK" || exit 1; mkdir -p host/caddy; echo "$1" > host/caddy/rp.caddy; git add -A; git commit -qm "caddy $1"; git push -q origin master ); }
run_caddy() { : > "$CV"; run_update CADDYFILE="$CF" CADDY_VALIDATE="$T/validate" CADDY_ACTIVE=true CADDY_RELOAD="$T/reload" "$@"; }
rc_is() { [ "$(rc)" = "$1" ]; }
said() { grep -q "$1" "$T/out.txt"; }
reloaded() { grep -qx RELOAD "$CV"; }

push_master v5; green_to_master; run_caddy
check "first tick with a Caddyfile: applies once (no stamp yet)" bash -c '[ "$(cat "'"$T"'/rc.txt")" = 0 ] && grep -qx RELOAD "'"$CV"'"'
run_caddy
check "stamp current: silent, nothing validated" bash -c '[ "$(cat "'"$T"'/rc.txt")" = 0 ] && [ ! -s "'"$CV"'" ] && [ ! -s "'"$T"'/out.txt" ]'
push_master v6; green_to_master; run_caddy
check "update with no snippet change: not validated" [ ! -s "$CV" ]

push_caddy good1; green_to_master; run_caddy
check "good snippet: exit 0"               rc_is 0
check "good snippet: validated the live Caddyfile" grep -q "VALIDATE $CF good1" "$CV"
check "good snippet: reloaded"             reloaded
check "good snippet: logged the reload"    said "reloaded Caddy"

good=$(at); push_caddy BROKEN; green_to_master; run_caddy
check "broken snippet: exit 1"             rc_is 1
check "broken snippet: rolled back"        [ "$(at)" = "$good" ]
check "broken snippet: old one back on disk" grep -qx good1 "$SELF/host/caddy/rp.caddy"
check "broken snippet: validated the old one too" grep -q "VALIDATE $CF good1" "$CV"
check "broken snippet: NOT reloaded"       bash -c '! grep -qx RELOAD "'"$CV"'"'
check "broken snippet: said REFUSING"      said REFUSING
run_caddy
check "next tick: refuses again, loudly"   bash -c '[ "$(cat "'"$T"'/rc.txt")" = 1 ] && grep -q REFUSING "'"$T"'/out.txt"'
check "next tick: still on the good commit" [ "$(at)" = "$good" ]
check "next tick: did not re-merge the refused commit" [ ! -s "$CV" ]
echo "# a comment" >> "$CF"; run_caddy
check "Caddyfile changed: the refused commit is retried" grep -q "VALIDATE $CF BROKEN" "$CV"
check "  ...and refused again"             bash -c '[ "$(cat "'"$T"'/rc.txt")" = 1 ] && [ "$(git -C "'"$SELF"'" rev-parse @)" = "'"$good"'" ]'
rm -f "$REFUSED"; run_caddy
check "rm of the refusal: retried by hand" grep -q "VALIDATE $CF BROKEN" "$CV"

push_caddy good2; green_to_master; run_caddy
check "fixed on master: exit 0"            rc_is 0
check "fixed on master: now on it"         grep -qx good2 "$SELF/host/caddy/rp.caddy"
check "fixed on master: reloaded"          reloaded

echo BROKEN >> "$CF"; push_caddy good3; green_to_master; run_caddy
check "Caddyfile broken on its own: goes forward" grep -qx good3 "$SELF/host/caddy/rp.caddy"
check "Caddyfile broken on its own: exit 1, says so" bash -c '[ "$(cat "'"$T"'/rc.txt")" = 1 ] && grep -q "old snippet too" "'"$T"'/out.txt"'
check "Caddyfile broken on its own: NOT reloaded" bash -c '! grep -qx RELOAD "'"$CV"'"'
run_caddy
check "  ...and says so again next tick, not silence" bash -c '[ "$(cat "'"$T"'/rc.txt")" = 1 ] && grep -q "does not validate" "'"$T"'/out.txt"'
rm -f "$STAMP"; push_master v7; green_to_master; run_caddy
check "  ...an update that does not touch the snippet: no rollback churn" bash -c '[ "$(grep -c VALIDATE "'"$CV"'")" = 1 ] && [ "$(cat "'"$SELF"'/VERSION")" = v7 ]'
echo "import $SELF/host/caddy/rp.caddy" > "$CF"; run_caddy
check "  ...until the Caddyfile is fixed: applied, then silent" bash -c '[ "$(cat "'"$T"'/rc.txt")" = 0 ] && grep -qx RELOAD "'"$CV"'"'

push_caddy good4; green_to_master; run_caddy CADDY_ACTIVE=false
check "Caddy not running: exit 0, no reload" bash -c '[ "$(cat "'"$T"'/rc.txt")" = 0 ] && ! grep -qx RELOAD "'"$CV"'"'

push_caddy good5; green_to_master; run_caddy CADDY_RELOAD=false
check "reload fails: exit 1, says so"      bash -c '[ "$(cat "'"$T"'/rc.txt")" = 1 ] && grep -q "reload failed" "'"$T"'/out.txt"'
run_caddy
check "  ...retried next tick, not silence" bash -c '[ "$(cat "'"$T"'/rc.txt")" = 0 ] && grep -qx RELOAD "'"$CV"'"'

push_caddy good6; run_caddy SITE_DEPLOY_REF=master; run_caddy
check "ahead of the gate: the snippet was still applied" bash -c 'grep -qx good6 "'"$SELF"'/host/caddy/rp.caddy" && [ "$(cat "'"$STAMP"'")" = "$(cd "'"$SELF"'" && git ls-tree -r HEAD -- host/caddy/ | grep "\.caddy$" | sha256sum | cut -c1-16)" ]'
rm -f "$STAMP"; run_caddy
check "ahead of the gate: an unapplied snippet converges" grep -qx RELOAD "$CV"
green_to_master; run_caddy

push_caddy good7; green_to_master; run_caddy CADDYFILE="$T/no-such-Caddyfile"
check "no Caddyfile: updates, exit 0"      bash -c '[ "$(cat "'"$T"'/rc.txt")" = 0 ] && grep -qx good7 "'"$SELF"'/host/caddy/rp.caddy"'
check "no Caddyfile: not validated"        [ ! -s "$CV" ]

echo
if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; else echo "all checks passed"; fi
exit $((fails > 0))
