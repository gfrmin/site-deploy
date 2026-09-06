#!/usr/bin/env bash
# Scenario tests for bin/auto-deploy.sh.
#
# No network, no root, no systemd, no Cloudflare. A throwaway bare git origin
# stands in for GitHub; `systemctl`, `uv` and `curl` are stubs on PATH that
# record what they were called with and can be told to fail. Modelled on
# dataguru's deploy/host/tests, which are the only tests this class of script
# has ever had.
#
# Each numbered run continues from the state the last one left, so idempotence
# is a real assertion rather than a claim.
#
# Every guard here has been verified by mutation — break it, watch the named
# check fail. One property deliberately is NOT covered: that the stylesheet is
# installed by an atomic rename rather than an in-place write. Replacing `mv`
# with `cat >` keeps this suite green, because proving atomicity needs a reader
# racing the writer, which is flaky in a way that costs more than it catches.
# The reason for the rename is in the comment at the call site instead.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); }
check() { local desc=$1; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

export STUB_LOG="$T/calls.log"
export STUB_UNITS="$T/units"
mkdir -p "$STUB_UNITS" "$T/bin"

# ── stubs ────────────────────────────────────────────────────────────────────
cat > "$T/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >> "$STUB_LOG"
if [ "${1:-}" = "is-active" ]; then
  f="$STUB_UNITS/${2}.state"
  if [ -f "$f" ]; then cat "$f"; else echo inactive; fi
  exit 0
fi
verb=${1:-}
[ "$verb" = "start" ] && [ "${2:-}" = "--no-block" ] && verb=start
if [ -n "${STUB_FAIL_VERB:-}" ] && [ "$verb" = "$STUB_FAIL_VERB" ]; then exit 1; fi
exit 0
STUB

cat > "$T/bin/uv" <<'STUB'
#!/usr/bin/env bash
echo "uv $*" >> "$STUB_LOG"
if [ "${1:-}" = "sync" ]; then [ -n "${STUB_FAIL_UV:-}" ] && exit 1; exit 0; fi
if [ "${1:-}" = "run" ] && [ "${2:-}" = "tailwindcss" ]; then
  [ -n "${STUB_FAIL_CSS:-}" ] && exit 1
  out=""; prev=""
  for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
  [ -n "$out" ] && printf '%s' "${STUB_CSS_CONTENT:-$(printf 'a%.0s' $(seq 1 4000))}" > "$out"
  exit 0
fi
exit 0
STUB

cat > "$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$STUB_LOG"
case "$*" in
  *purge_cache*) printf '{"success":true}\n200\n'; exit 0 ;;
esac
if [ -n "${STUB_HEALTH_FAIL:-}" ]; then exit 22; fi
printf '%s' "${STUB_HEALTH_BODY:-{\"status\":\"ok\"}}"
exit 0
STUB
chmod +x "$T/bin"/*
export PATH="$T/bin:$PATH"

# ── a throwaway origin and a checkout ────────────────────────────────────────
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
ORIGIN="$T/origin.git"; WORK="$T/work"; SRV="$T/srv/app"
git init -q --bare "$ORIGIN"
git clone -q "$ORIGIN" "$WORK" 2>/dev/null
( cd "$WORK" || exit 1
  mkdir -p static data
  printf '@tailwind base;' > static/src.css
  printf 'static/app.css\n' > .gitignore
  echo "print('x')" > data/build_db.py
  git add -A && git commit -qm init && git branch -M master && git push -q origin master )
git clone -q "$ORIGIN" "$SRV" 2>/dev/null
printf 'a%.0s' $(seq 1 4000) > "$SRV/static/app.css"   # the currently-served stylesheet

push_commit() { ( cd "$WORK" || exit 1; echo "$1" >> notes.txt; git add -A; git commit -qm "$1"; git push -q origin master ); }
reset_log() { : > "$STUB_LOG"; }
called() { grep -qF "$1" "$STUB_LOG"; }
not_called() { ! grep -qF "$1" "$STUB_LOG"; }

run_deploy() {
  env APP=app APP_DIR="$SRV" SITE_DEPLOY_DIR="$ROOT" UV="$T/bin/uv" CURL="$T/bin/curl" \
      RELOAD_CMD="$T/bin/systemctl" PORT=8000 DEPLOY_HEALTH_TRIES=2 \
      CF_ZONE_ID=zone1 CF_CACHE_PURGE_TOKEN=tok1 \
      "$@" bash "$ROOT/bin/auto-deploy.sh" > "$T/out.txt" 2>&1
  echo $? > "$T/rc.txt"
}
rc() { cat "$T/rc.txt"; }
out() { cat "$T/out.txt"; }

echo "1. up to date -> silent no-op"
reset_log; run_deploy
check "exit 0"            [ "$(rc)" = 0 ]
check "printed nothing"   [ -z "$(out)" ]
check "did not reload"    not_called "systemctl reload"

echo "2. remote ahead -> syncs, reloads, purges"
push_commit c2; reset_log; run_deploy
check "exit 0"                 [ "$(rc)" = 0 ]
check "ran uv sync"            called "uv sync"
check "reloaded the app"       called "systemctl reload app"
check "purged the edge"        called "purge_cache"
check "logged the deploy"      grep -q "deployed" "$T/out.txt"

echo "3. post-reload health gate runs BEFORE the purge"
push_commit c3; reset_log; run_deploy
check "probed health"          called "127.0.0.1:8000/health"
check "health before purge"    bash -c 'h=$(grep -n "127.0.0.1:8000/health" "$STUB_LOG" | head -1 | cut -d: -f1); p=$(grep -n purge_cache "$STUB_LOG" | head -1 | cut -d: -f1); [ -n "$h" ] && [ -n "$p" ] && [ "$h" -lt "$p" ]'

echo "4. unhealthy after reload -> NO purge, and the unit fails"
push_commit c4; reset_log; STUB_HEALTH_FAIL=1 run_deploy STUB_HEALTH_FAIL=1
check "exit non-zero"          [ "$(rc)" != 0 ]
check "did NOT purge"          not_called "purge_cache"
check "said why"               grep -qi "health" "$T/out.txt"

echo "5. local ahead of origin is benign, not fatal"
( cd "$SRV" || exit 1; echo local >> local.txt; git add -A; git commit -qm "local-only" )
reset_log; run_deploy
check "exit 0 (self-healing)"  [ "$(rc)" = 0 ]
check "did not reload"         not_called "systemctl reload"
check "said local is ahead"    grep -qi "ahead" "$T/out.txt"
( cd "$SRV" || exit 1; git reset -q --hard origin/master )

echo "6. genuinely diverged is still fatal"
( cd "$SRV" || exit 1; git reset -q --hard HEAD~1; echo diverge >> d.txt; git add -A; git commit -qm diverged )
push_commit c6; reset_log; run_deploy
check "exit 1"                 [ "$(rc)" = 1 ]
check "did not reload"         not_called "systemctl reload"
( cd "$SRV" || exit 1; git fetch -q origin; git reset -q --hard origin/master )

echo "7. a build unit in 'deactivating' counts as busy"
echo deactivating > "$STUB_UNITS/app-build.service.state"
push_commit "c7 build" ; ( cd "$WORK" || exit 1; echo "# changed" >> data/build_db.py; git commit -qam "touch builder"; git push -q origin master )
reset_log; run_deploy DEPLOY_BUILD_SERVICE=app-build.service
check "queued, did not start"  not_called "systemctl start --no-block app-build.service"
check "wrote the queue flag"   [ -f "$SRV/.site-deploy-build-pending" ]
check "said it queued"         grep -qi "queue" "$T/out.txt"

echo "8. once the build unit is idle the queued rebuild is dispatched"
echo inactive > "$STUB_UNITS/app-build.service.state"
reset_log; run_deploy DEPLOY_BUILD_SERVICE=app-build.service
check "started the build"      called "systemctl start --no-block app-build.service"
check "cleared the flag"       [ ! -f "$SRV/.site-deploy-build-pending" ]

echo "9. a collapsed stylesheet is refused and blocks the reload"
cp "$SRV/static/app.css" "$T/app.css.before"
push_commit c9; reset_log; run_deploy STUB_CSS_CONTENT="/*empty*/"
check "exit non-zero"          [ "$(rc)" != 0 ]
check "did not reload"         not_called "systemctl reload"
check "did not purge"          not_called "purge_cache"
check "served css untouched"   cmp -s "$SRV/static/app.css" "$T/app.css.before"
check "said why"               grep -qiE "css|stylesheet" "$T/out.txt"

echo "9b. the size FLOOR alone catches a first build with nothing to compare against"
rm -f "$SRV/static/app.css"                       # no previous stylesheet -> no ratio to compute
push_commit c9b; reset_log; run_deploy STUB_CSS_CONTENT="/*tiny*/"
check "exit non-zero"          [ "$(rc)" != 0 ]
check "did not reload"         not_called "systemctl reload"
check "installed nothing"      [ ! -f "$SRV/static/app.css" ]
check "named the floor"        grep -qi "floor" "$T/out.txt"
printf 'a%.0s' $(seq 1 4000) > "$SRV/static/app.css"

echo "9c. the RATIO alone catches a collapse that clears the floor"
reset_log; run_deploy STUB_CSS_CONTENT="$(printf 'c%.0s' $(seq 1 1500))"
check "exit non-zero"          [ "$(rc)" != 0 ]
check "did not reload"         not_called "systemctl reload"
check "kept the old stylesheet" bash -c '[ "$(wc -c < "'"$SRV"'/static/app.css")" -eq 4000 ]'
check "named the collapse"     grep -qi "collapsed" "$T/out.txt"

echo "10. the half-finished deploy from run 9 resumes, though git is up to date"
# Run 9 merged and then failed, so the checkout is already at origin/master. Without
# the resume marker this tick would exit 0 silently, turn the failed unit green, and
# leave the box running the old workers behind new templates.
check "git really is up to date" bash -c 'cd "'"$SRV"'" && [ "$(git rev-parse @)" = "$(git rev-parse @{u})" ]'
reset_log; run_deploy STUB_CSS_CONTENT="$(printf 'b%.0s' $(seq 1 3900))"
check "resumed, not skipped"   grep -qi "resuming" "$T/out.txt"
check "exit 0"                 [ "$(rc)" = 0 ]
check "reloaded"               called "systemctl reload app"
check "css replaced"           bash -c '! cmp -s "'"$SRV"'/static/app.css" "'"$T"'/app.css.before"'
check "no temp left behind"    bash -c '! ls "'"$SRV"'"/static/.app.css.* >/dev/null 2>&1'

echo "10b. deploy/site.toml supplies the knobs, and overrides a stale env value"
( cd "$WORK" || exit 1; mkdir -p deploy
  printf '[deploy]\nreload = "restart"\nport = 8000\nhealth_path = "/health"\nhealth_match = "ok"\nhealth_tries = 2\n' > deploy/site.toml
  git add -A; git commit -qm "site.toml"; git push -q origin master )
reset_log; run_deploy DEPLOY_RELOAD=reload
check "used site.toml's verb"   called "systemctl restart app"
check "not the env's verb"      not_called "systemctl reload app"
check "reported the override"   grep -q "site.toml sets DEPLOY_RELOAD" "$T/out.txt"
check "health match honoured"   called "127.0.0.1:8000/health"

echo "10c. a body that does not match the declared string is unhealthy"
push_commit c10c; reset_log; run_deploy STUB_HEALTH_BODY="Internal Server Error"
check "exit non-zero"           [ "$(rc)" != 0 ]
check "did not purge"           not_called "purge_cache"

echo "10d. a malformed site.toml refuses to deploy rather than guessing"
( cd "$WORK" || exit 1; printf '[deploy\nreload = ' > deploy/site.toml; git commit -qam "break it"; git push -q origin master )
reset_log; run_deploy
check "exit non-zero"           [ "$(rc)" != 0 ]
check "did not reload"          not_called "systemctl restart app"
check "said why"                grep -qi "site.toml" "$T/out.txt"
( cd "$WORK" || exit 1
  printf '[deploy]\nreload = "restart"\nport = 8000\nhealth_path = "/health"\nhealth_match = "ok"\nhealth_tries = 2\n' > deploy/site.toml
  git commit -qam "fix it"; git push -q origin master )
reset_log; run_deploy
check "recovers once fixed"     [ "$(rc)" = 0 ]

echo "11. idempotent: nothing left to do is silent again"
reset_log; run_deploy
check "exit 0"                 [ "$(rc)" = 0 ]
check "printed nothing"        [ -z "$(out)" ]

echo
if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; else echo "all checks passed"; fi
exit $((fails > 0))
