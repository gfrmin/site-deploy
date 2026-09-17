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
fail() { echo "  FAIL $1"; fails=$((fails + 1)); [ -s "$T/out.txt" ] && sed 's/^/         | /' "$T/out.txt" | tail -8; }
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
if [ "${1:-}" = "show" ] && [ "${2:-}" = "-p" ] && [ "${3:-}" = "ExecReload" ]; then
  if [ "${STUB_EXEC_RELOAD+set}" = set ]; then printf '%s\n' "$STUB_EXEC_RELOAD"
  else echo '{ path=/bin/kill ; argv[]=/bin/kill -HUP $MAINPID }'; fi
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
if [ "${1:-}" = "run" ] && printf '%s\n' "$@" | grep -qx tailwindcss; then
  echo "tailwindcss-version=${TAILWINDCSS_VERSION:-unset}" >> "$STUB_LOG"
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
  *hc.example*) exit 0 ;;                    # a dead-man ping: always delivered
esac
if [ -n "${STUB_HEALTH_FAIL:-}" ]; then exit 22; fi
# A non-2xx answer: real curl prints the body and exits 0, unless -f is given,
# in which case it prints nothing and exits 22.
if [ -n "${STUB_HEALTH_STATUS:-}" ] && [ "$STUB_HEALTH_STATUS" -ge 400 ]; then
  if printf '%s\n' "$@" | grep -qxE -- '-f|-fsS|-fs|-sf|-sSf'; then exit 22; fi
fi
body=${STUB_HEALTH_BODY:-}; [ -n "$body" ] || body='{"status":"ok"}'
printf '%s' "$body"
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
called() { grep -qF -e "$1" "$STUB_LOG"; }
not_called() { ! grep -qF -e "$1" "$STUB_LOG"; }

# Every privileged hook is stubbed HERE, unconditionally, and not only in the
# runs that exercise it: the poller's defaults are `sudo -n ...`, and on a dev
# box with passwordless sudo an unstubbed run converges the REAL host. It
# happened once. A stub that is always present cannot be forgotten by a run.
cat > "$T/bin/host-converge" <<'STUB'
#!/usr/bin/env bash
echo "HOST-CONVERGE RAN $*" >> "$STUB_LOG"
exit ${FAKE_HOST_CONVERGE_RC:-0}
STUB
chmod +x "$T/bin/host-converge"
# Same reasoning as host-converge above, for the fallback [converge]-table
# engine: stub it unconditionally so an app with converge=true and no
# deploy/converge.sh cannot fall through to the REAL bin/converge.sh reading
# a real /srv/<app>/deploy/site.toml on the dev box. Its own behaviour is
# covered in depth by tests/test-converge.sh; this file only checks the
# WIRING (when it is dispatched, and how a failure is handled).
cat > "$T/bin/converge-engine" <<'STUB'
#!/usr/bin/env bash
echo "CONVERGE-ENGINE RAN $*" >> "$STUB_LOG"
exit ${FAKE_CONVERGE_ENGINE_RC:-0}
STUB
chmod +x "$T/bin/converge-engine"
run_deploy() {
  env APP=app APP_DIR="$SRV" SITE_DEPLOY_DIR="$ROOT" UV="$T/bin/uv" CURL="$T/bin/curl" \
      RELOAD_CMD="$T/bin/systemctl" PORT=8000 DEPLOY_HEALTH_TRIES=2 \
      CF_ZONE_ID=zone1 CF_CACHE_PURGE_TOKEN=tok1 \
      CONVERGE_CMD=env HOST_CONVERGE_CMD="$T/bin/host-converge" \
      CONVERGE_ENGINE_CMD="$T/bin/converge-engine" DEPLOY_REF_FILE="$T/deploy-ref" \
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

echo "11b. converge = true with no deploy/converge.sh falls back to the toolkit engine"
( cd "$WORK" || exit 1
  printf '[deploy]\nreload = "restart"\nport = 8000\nhealth_path = "/health"\nhealth_match = "ok"\nhealth_tries = 2\nconverge = true\n' > deploy/site.toml
  git commit -qam "converge on, no script yet"; git push -q origin master )
reset_log; run_deploy CONVERGE_CMD=env
check "exit 0"                  [ "$(rc)" = 0 ]
check "dispatched the engine"   called "CONVERGE-ENGINE RAN"
check "reloaded"                called "systemctl restart app"

echo "11c. a failing engine stops the deploy BEFORE the reload, same as a failing app script"
push_commit c11c; reset_log; run_deploy CONVERGE_CMD=env FAKE_CONVERGE_ENGINE_RC=1
check "exit non-zero"           [ "$(rc)" != 0 ]
check "tried the engine"        called "CONVERGE-ENGINE RAN"
check "did NOT reload"          not_called "systemctl restart app"
check "said why"                grep -qi "converge.sh failed" "$T/out.txt"
( cd "$WORK" || exit 1; printf '[deploy]\nreload = "restart"\nport = 8000\nhealth_path = "/health"\nhealth_match = "ok"\nhealth_tries = 2\n' > deploy/site.toml
  git commit -qam "converge off again"; git push -q origin master )
reset_log; run_deploy CONVERGE_CMD=env
check "recovers once converge is off"  [ "$(rc)" = 0 ]

# Converging box config is the one step here that runs as root, so its failure
# modes matter more than most: the thing it can get wrong is reloading the app
# onto half-applied units.
echo "12a. converge is opt-in: an undeclared knob never runs the script"
( cd "$WORK" || exit 1
  printf '#!/usr/bin/env bash\necho "CONVERGE RAN" >> "$STUB_LOG"\nexit ${FAKE_CONVERGE_RC:-0}\n' > deploy/converge.sh
  chmod +x deploy/converge.sh
  git add deploy/converge.sh; git commit -qm "add converge script"; git push -q origin master )
reset_log; run_deploy CONVERGE_CMD=env
check "exit 0"                  [ "$(rc)" = 0 ]
check "did not converge"        not_called "CONVERGE RAN"
check "still reloaded"          called "systemctl restart app"

echo "12b. converge = true runs it, then reloads"
( cd "$WORK" || exit 1
  printf '[deploy]\nreload = "restart"\nport = 8000\nhealth_path = "/health"\nhealth_match = "ok"\nhealth_tries = 2\nconverge = true\n' > deploy/site.toml
  git commit -qam "converge on"; git push -q origin master )
reset_log; run_deploy CONVERGE_CMD=env
check "exit 0"                  [ "$(rc)" = 0 ]
check "converged"               called "CONVERGE RAN"
check "reloaded"                called "systemctl restart app"

echo "12c. a failing converge stops the deploy BEFORE the reload"
# The point of the whole step: units that did not apply must never get traffic,
# and the edge must keep serving the old site rather than be purged onto a box
# in an unknown state.
push_commit c12c; reset_log; run_deploy CONVERGE_CMD=env FAKE_CONVERGE_RC=1
check "exit non-zero"           [ "$(rc)" != 0 ]
check "tried to converge"       called "CONVERGE RAN"
check "did NOT reload"          not_called "systemctl restart app"
check "did NOT purge"           not_called "purge_cache"
check "said why"                grep -qi "converge" "$T/out.txt"

echo "12d. declared but unusable refuses to deploy rather than deploying blind"
( cd "$WORK" || exit 1; chmod -x deploy/converge.sh; git update-index --chmod=-x deploy/converge.sh
  git commit -qam "break converge"; git push -q origin master )
reset_log; run_deploy CONVERGE_CMD=env
check "exit non-zero"           [ "$(rc)" != 0 ]
check "did NOT reload"          not_called "systemctl restart app"
check "named the problem"       grep -qi "converge.sh is not executable" "$T/out.txt"

echo "12e. root never runs a converge script out of a checkout that differs from the commit"
# converge.sh runs as root via NOPASSWD from a directory the service user can
# write. An RCE in the app would edit deploy/converge.sh in place and wait two
# minutes for the poller to hand it root. The guard: the working tree under
# deploy/ must match HEAD byte for byte before root touches it.
( cd "$WORK" || exit 1; chmod +x deploy/converge.sh; git update-index --chmod=+x deploy/converge.sh
  git commit -qam "fix converge"; git push -q origin master )
reset_log; run_deploy CONVERGE_CMD=env
check "sane baseline: converged"  called "CONVERGE RAN"
echo 'echo PWNED >> "$STUB_LOG"' >> "$SRV/deploy/converge.sh"    # a tracked file, edited on the box
push_commit c12e; reset_log; run_deploy CONVERGE_CMD=env
check "exit non-zero"             [ "$(rc)" != 0 ]
check "did NOT run converge"      not_called "CONVERGE RAN"
check "did NOT reload"            not_called "systemctl restart app"
check "named the modified file"   grep -q "deploy/converge.sh" "$T/out.txt"
( cd "$SRV" || exit 1; git checkout -q -- deploy/converge.sh )

echo "12f. an UNTRACKED file under deploy/ is the same refusal"
# Untracked is not "not a problem": a converge engine that installs deploy/systemd/*
# would happily install a unit nobody committed.
echo "[Unit]" > "$SRV/deploy/rogue.service"
push_commit c12f; reset_log; run_deploy CONVERGE_CMD=env
check "exit non-zero"             [ "$(rc)" != 0 ]
check "did NOT run converge"      not_called "CONVERGE RAN"
check "named the untracked file"  grep -q "deploy/rogue.service" "$T/out.txt"
rm -f "$SRV/deploy/rogue.service"

echo "12g. clean again -> converges and finishes the deploy it refused"
reset_log; run_deploy CONVERGE_CMD=env
check "exit 0"                    [ "$(rc)" = 0 ]
check "converged"                 called "CONVERGE RAN"
check "reloaded"                  called "systemctl restart app"

# ── latent bugs surfaced by comparing against the monorepo's poller ──────────
echo "13a. the CSS build runs uv with --frozen --no-dev"
# An unflagged `uv run` re-locks uv.lock in the checkout on a pyproject/lock
# mismatch, after which every ff-only merge fails forever as "drift".
( cd "$WORK" || exit 1
  printf '[deploy]\nreload = "reload"\nport = 8000\nhealth_path = "/health"\nhealth_match = "ok"\nhealth_tries = 2\nconverge = true\n' > deploy/site.toml
  git commit -qam "back to reload"; git push -q origin master )
reset_log; run_deploy CONVERGE_CMD=env
check "exit 0"                     [ "$(rc)" = 0 ]
check "frozen, no-dev"             called "uv run --frozen --no-dev tailwindcss"

echo "13b. a deploy that changes uv.lock RESTARTS instead of reloading"
# SIGHUP re-forks workers under the interpreter and gunicorn the arbiter was
# started with; only a restart execs the newly synced ones.
( cd "$WORK" || exit 1; echo "version = 1" > uv.lock; git add uv.lock; git commit -qm "add lock"; git push -q origin master )
reset_log; run_deploy CONVERGE_CMD=env
check "exit 0"                     [ "$(rc)" = 0 ]
check "restarted"                  called "systemctl restart app"
check "did not merely reload"      not_called "systemctl reload app"
check "said why"                   grep -q "uv.lock" "$T/out.txt"

echo "13c. a uv.lock re-locked in place on the box is discarded, not deployed over"
( cd "$WORK" || exit 1; echo "version = 2" > uv.lock; git commit -qam "bump lock"; git push -q origin master )
echo "machine-written" >> "$SRV/uv.lock"
reset_log; run_deploy CONVERGE_CMD=env
check "exit 0"                     [ "$(rc)" = 0 ]
check "merged the new lock"        [ "$(cat "$SRV/uv.lock")" = "version = 2" ]
check "said it discarded"          grep -qi "uv.lock is MODIFIED" "$T/out.txt"
check "restarted"                  called "systemctl restart app"

echo "13d. with health_match set the BODY is the datum: a 503 whose body matches is up"
# /health on a snapshot-backed app answers 503 on a stale snapshot while serving
# every page. A `-f` probe would call it down, skip the purge, and strand the
# deploy's templates at the edge for a full TTL.
push_commit c13d; reset_log; run_deploy CONVERGE_CMD=env STUB_HEALTH_STATUS=503
check "exit 0"                     [ "$(rc)" = 0 ]
check "purged"                     called "purge_cache"

echo "13e. with NO health_match the status code is the datum: a 503 is down"
# Also pins that a knob REMOVED by the deploying commit is really gone: the
# pre-merge read of the old site.toml must not leave health_match exported.
( cd "$WORK" || exit 1
  printf '[deploy]\nreload = "reload"\nport = 8000\nhealth_path = "/health"\nhealth_tries = 2\nconverge = true\n' > deploy/site.toml
  git commit -qam "no match"; git push -q origin master )
reset_log; run_deploy CONVERGE_CMD=env STUB_HEALTH_STATUS=503
check "exit non-zero"              [ "$(rc)" != 0 ]
check "did not purge"              not_called "purge_cache"
( cd "$WORK" || exit 1
  printf '[deploy]\nreload = "reload"\nport = 8000\nhealth_path = "/health"\nhealth_match = "ok"\nhealth_tries = 2\nconverge = true\ntailwindcss_version = "4.3.3"\n' > deploy/site.toml
  git commit -qam "match + pin"; git push -q origin master )
reset_log; run_deploy CONVERGE_CMD=env     # resume the refused deploy, and take the pin

echo "13f. tailwindcss_version in site.toml pins the compiler"
# pytailwindcss downloads releases/latest with the variable unset: the
# stylesheet every visitor gets is then compiled by whichever version upstream
# had published when that box's venv was created.
check "pin reached the build"      called "tailwindcss-version=4.3.3"

echo "13g. an @source that does not resolve on this box refuses the build"
# tailwindcss exits 0 with a near-empty stylesheet when a source path is
# mistyped, and the ratio guard alone misses apps whose src.css is mostly
# hand-written CSS.
( cd "$WORK" || exit 1; printf '@import "tailwindcss" source(none);\n@source "../templates/**/*.html";\n' > static/src.css
  git commit -qam "declare a source"; git push -q origin master )
reset_log; run_deploy CONVERGE_CMD=env
check "exit non-zero"              [ "$(rc)" != 0 ]
check "did not build"              not_called "tailwindcss"
check "did not reload"             not_called "systemctl reload app"
check "named the source"           grep -q "templates" "$T/out.txt"

echo "13h. once the source exists the same commit deploys"
( cd "$WORK" || exit 1; mkdir -p templates; touch templates/x.html; git add -A; git commit -qm "add templates"; git push -q origin master )
reset_log; run_deploy CONVERGE_CMD=env
check "exit 0"                     [ "$(rc)" = 0 ]
check "built"                      called "tailwindcss"
check "reloaded"                   called "systemctl reload app"

echo "13i. an @source form the check does not model is reported, not skipped"
( cd "$WORK" || exit 1; printf '@import "tailwindcss" source(none);\n@source "../templates/**/*.html";\n@source not "../vendor";\n' > static/src.css
  git commit -qam "unmodelled source"; git push -q origin master )
reset_log; run_deploy CONVERGE_CMD=env
check "exit non-zero"              [ "$(rc)" != 0 ]
check "said unmodelled"            grep -qi "does not model" "$T/out.txt"
( cd "$WORK" || exit 1; printf '@import "tailwindcss" source(none);\n@source "../templates/**/*.html";\n' > static/src.css
  git commit -qam "fix source"; git push -q origin master )
reset_log; run_deploy CONVERGE_CMD=env
check "recovers"                   [ "$(rc)" = 0 ]

# ── the deploy dead-man ──────────────────────────────────────────────────────
# Subject: "this box is AT the ref it should be at" — not "a tick ran". A
# ran-dead-man is green during the failure it most needs to catch (a fetch that
# has failed every two minutes for a week).
HC=https://hc.example/deploy1
hc_calls() { grep -c "hc.example" "$STUB_LOG" || true; }
echo "14a. an idle, level tick pings the check root and is still silent"
reset_log; run_deploy CONVERGE_CMD=env HEALTHCHECKS_DEPLOY_URL=$HC/
check "exit 0"                     [ "$(rc)" = 0 ]
check "printed nothing"            [ -z "$(out)" ]
check "pinged root, once"          bash -c 'grep -c "https://hc.example/deploy1 *$" "$STUB_LOG" | grep -qx 1'
check "no double slash"            not_called "deploy1//"
check "no /fail, no /start"        bash -c '! grep -qE "deploy1/(fail|start)" "$STUB_LOG"'

echo "14b. a deploying tick pings /start before it reloads, root after health passes"
push_commit c14b; reset_log; run_deploy CONVERGE_CMD=env HEALTHCHECKS_DEPLOY_URL=$HC
check "exit 0"                     [ "$(rc)" = 0 ]
check "pinged /start"              called "deploy1/start"
check "start before reload"        bash -c 's=$(grep -n "deploy1/start" "$STUB_LOG" | head -1 | cut -d: -f1); r=$(grep -n "systemctl reload app" "$STUB_LOG" | head -1 | cut -d: -f1); [ -n "$s" ] && [ -n "$r" ] && [ "$s" -lt "$r" ]'
check "root after health"          bash -c 'h=$(grep -n "8000/health" "$STUB_LOG" | tail -1 | cut -d: -f1); p=$(grep -n "https://hc.example/deploy1 *$" "$STUB_LOG" | tail -1 | cut -d: -f1); [ -n "$h" ] && [ -n "$p" ] && [ "$h" -lt "$p" ]'

echo "14c. a failed step pings /fail with the reason, never root"
push_commit c14c; reset_log; run_deploy CONVERGE_CMD=env HEALTHCHECKS_DEPLOY_URL=$HC STUB_FAIL_UV=1
check "exit non-zero"              [ "$(rc)" != 0 ]
check "pinged /fail"               called "deploy1/fail"
check "body names the step"        bash -c 'grep "deploy1/fail" "$STUB_LOG" | grep -q "uv sync failed"'
check "no root ping"               bash -c '! grep -q "https://hc.example/deploy1 *$" "$STUB_LOG"'
reset_log; run_deploy CONVERGE_CMD=env HEALTHCHECKS_DEPLOY_URL=$HC        # resume, heal
check "healed: root again"         called "https://hc.example/deploy1"

echo "14d. a fetch that keeps failing is a stuck box: /fail once it has persisted"
git -C "$SRV" remote set-url origin "$T/nowhere.git"
reset_log; run_deploy CONVERGE_CMD=env HEALTHCHECKS_DEPLOY_URL=$HC
check "exit 0 (transient)"         [ "$(rc)" = 0 ]
check "no /fail yet"               not_called "deploy1/fail"
check "no root either"             bash -c '! grep -q "https://hc.example/deploy1 *$" "$STUB_LOG"'
check "stamped the stall"          [ -f "$SRV/.site-deploy-state/behind-since" ]
echo 1000000000 > "$SRV/.site-deploy-state/behind-since"       # pretend it started long ago
reset_log; run_deploy CONVERGE_CMD=env HEALTHCHECKS_DEPLOY_URL=$HC
check "exit 0 still"               [ "$(rc)" = 0 ]
check "pinged /fail"               called "deploy1/fail"
check "said stuck"                 grep -qi "STUCK" "$T/out.txt"
git -C "$SRV" remote set-url origin "$ORIGIN"
reset_log; run_deploy CONVERGE_CMD=env HEALTHCHECKS_DEPLOY_URL=$HC
check "level again: root"          called "https://hc.example/deploy1"
check "stamp cleared"              [ ! -f "$SRV/.site-deploy-state/behind-since" ]

echo "14e. unset URL: no ping, still silent"
reset_log; run_deploy CONVERGE_CMD=env
check "no hc call"                 [ "$(hc_calls)" = 0 ]
check "printed nothing"            [ -z "$(out)" ]

# ── deploy_ref: deploy the TESTED ref, not the tip of master ─────────────────
site_toml() { ( cd "$WORK" || exit 1; printf '%s\n' "$@" > deploy/site.toml; git commit -qam "site.toml: $*"; git push -q origin master ); }
BASE=('[deploy]' 'reload = "reload"' 'port = 8000' 'health_path = "/health"' 'health_match = "ok"' 'health_tries = 2' 'converge = true' 'tailwindcss_version = "4.3.3"')
echo "15a. deploy_ref names a ref that does not exist -> REFUSES, keeps serving, says how to bypass"
# A gate that opens when it cannot find its own lock is not a gate.
site_toml "${BASE[@]}" 'deploy_ref = "ci-green"'
reset_log; run_deploy CONVERGE_CMD=env                    # takes the site.toml change (still on master)
reset_log; run_deploy CONVERGE_CMD=env HEALTHCHECKS_DEPLOY_URL=$HC
check "exit 1"                     [ "$(rc)" = 1 ]
check "did not reload"             not_called "systemctl reload app"
check "said REFUSING"              grep -q "REFUSING" "$T/out.txt"
check "named the override"         grep -q "deploy-ref" "$T/out.txt"
check "dead-man got /fail"         called "deploy1/fail"

echo "15b. the ref exists at master -> deploys onto it"
( cd "$WORK" || exit 1; git push -q origin master:refs/heads/ci-green )
reset_log; run_deploy CONVERGE_CMD=env
check "exit 0"                     [ "$(rc)" = 0 ]
check "silent (level)"             [ -z "$(out)" ]

echo "15c. master runs ahead of the ref -> nothing deployed, said out loud"
push_commit c15c; reset_log; run_deploy CONVERGE_CMD=env HEALTHCHECKS_DEPLOY_URL=$HC
check "exit 0"                     [ "$(rc)" = 0 ]
check "did not reload"             not_called "systemctl reload app"
check "said behind"                grep -qi "behind origin/master" "$T/out.txt"
check "still level (root ping)"    called "https://hc.example/deploy1"
check "untested commit not taken"  bash -c 'cd "'"$SRV"'" && [ "$(git rev-parse @)" = "$(git rev-parse origin/ci-green)" ]'

echo "15d. the ref has not moved for an hour while master is ahead -> the box is NOT where it should be"
echo "$(git -C "$SRV" rev-parse origin/ci-green) 1000000000" > "$SRV/.site-deploy-state/ref-frozen-since"
reset_log; run_deploy CONVERGE_CMD=env HEALTHCHECKS_DEPLOY_URL=$HC
check "exit 0 (nothing to do)"     [ "$(rc)" = 0 ]
check "said FROZEN"                grep -q "FROZEN" "$T/out.txt"
check "dead-man got /fail"         called "deploy1/fail"
check "no root ping"               bash -c '! grep -q "https://hc.example/deploy1 *$" "$STUB_LOG"'

echo "15e. the ref advances -> deploys, and the frozen clock resets"
( cd "$WORK" || exit 1; git push -q origin master:refs/heads/ci-green )
reset_log; run_deploy CONVERGE_CMD=env HEALTHCHECKS_DEPLOY_URL=$HC
check "exit 0"                     [ "$(rc)" = 0 ]
check "reloaded"                   called "systemctl reload app"
check "clock cleared"              [ ! -f "$SRV/.site-deploy-state/ref-frozen-since" ]

echo "15f. a narrowed remote.origin.fetch cannot starve the ref"
git -C "$SRV" config remote.origin.fetch '+refs/heads/master:refs/remotes/origin/master'
git -C "$SRV" update-ref -d refs/remotes/origin/ci-green
push_commit c15f; ( cd "$WORK" || exit 1; git push -q origin master:refs/heads/ci-green )
reset_log; run_deploy CONVERGE_CMD=env
check "exit 0"                     [ "$(rc)" = 0 ]
check "deployed the ref"           called "systemctl reload app"
git -C "$SRV" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'

echo "15g. the /etc override file wins over site.toml (an emergency, deliberately not converged)"
push_commit c15g                                                  # master ahead of ci-green again
echo master > "$T/deploy-ref"
reset_log; run_deploy CONVERGE_CMD=env DEPLOY_REF_FILE="$T/deploy-ref"
check "exit 0"                     [ "$(rc)" = 0 ]
check "deployed master"            called "systemctl reload app"
check "said which ref"             grep -q "origin/master" "$T/out.txt"
rm -f "$T/deploy-ref"
( cd "$WORK" || exit 1; git push -q origin master:refs/heads/ci-green )
reset_log; run_deploy CONVERGE_CMD=env
check "level again"                [ "$(rc)" = 0 ]

# ── the reload contract ───────────────────────────────────────────────────────
echo "16a. reload = \"reload\" against a unit with no ExecReload= refuses (the verb would be a no-op)"
push_commit c16a; ( cd "$WORK" || exit 1; git push -q origin master:refs/heads/ci-green )
reset_log; run_deploy CONVERGE_CMD=env STUB_EXEC_RELOAD=""
check "exit non-zero"              [ "$(rc)" != 0 ]
check "did not reload"             not_called "systemctl reload app"
check "did not purge"              not_called "purge_cache"
check "named ExecReload"           grep -q "ExecReload" "$T/out.txt"
reset_log; run_deploy CONVERGE_CMD=env                          # unit fixed (stub default) -> resumes
check "resumed once fixed"         called "systemctl reload app"

echo "16b. reload = \"reload\" with preload_app = True in gunicorn.conf.py refuses (SIGHUP would not re-import)"
( cd "$WORK" || exit 1; printf 'workers = 3\npreload_app = True\n' > gunicorn.conf.py; git add -A; git commit -qm "preload"; git push -q origin master; git push -q origin master:refs/heads/ci-green )
reset_log; run_deploy CONVERGE_CMD=env
check "exit non-zero"              [ "$(rc)" != 0 ]
check "did not reload"             not_called "systemctl reload app"
check "named preload_app"          grep -q "preload_app" "$T/out.txt"
( cd "$WORK" || exit 1; printf 'workers = 3\npreload_app = False\n' > gunicorn.conf.py; git commit -qam "no preload"; git push -q origin master; git push -q origin master:refs/heads/ci-green )
reset_log; run_deploy CONVERGE_CMD=env
check "recovers"                   [ "$(rc)" = 0 ]

echo "16c. reload = \"restart\" needs neither"
site_toml "${BASE[@]/reload = \"reload\"/reload = \"restart\"}" 'deploy_ref = "ci-green"'
( cd "$WORK" || exit 1; printf 'preload_app = True\n' > gunicorn.conf.py; git commit -qam "preload again"; git push -q origin master; git push -q origin master:refs/heads/ci-green )
reset_log; run_deploy CONVERGE_CMD=env STUB_EXEC_RELOAD=""
check "exit 0"                     [ "$(rc)" = 0 ]
check "restarted"                  called "systemctl restart app"

# ── host-converge runs BEFORE the app's converge, and its failure stops the deploy ──
echo "17a. converge = true also converges the host, first"
site_toml "${BASE[@]}" 'deploy_ref = "ci-green"'
( cd "$WORK" || exit 1; printf 'preload_app = False\n' > gunicorn.conf.py; git commit -qam "fix preload"; git push -q origin master; git push -q origin master:refs/heads/ci-green )
reset_log; run_deploy
check "exit 0"                     [ "$(rc)" = 0 ]
check "host converged"             called "HOST-CONVERGE RAN app"
check "host before app"            bash -c 'h=$(grep -n "HOST-CONVERGE RAN" "$STUB_LOG" | head -1 | cut -d: -f1); a=$(grep -n "CONVERGE RAN" "$STUB_LOG" | grep -v HOST | head -1 | cut -d: -f1); [ -n "$h" ] && [ -n "$a" ] && [ "$h" -lt "$a" ]'

echo "17b. a failing host-converge stops the deploy before the app converge and the reload"
push_commit c17b; ( cd "$WORK" || exit 1; git push -q origin master:refs/heads/ci-green )
reset_log; run_deploy FAKE_HOST_CONVERGE_RC=1
check "exit non-zero"              [ "$(rc)" != 0 ]
check "app converge NOT run"       bash -c '! grep -v HOST "$STUB_LOG" | grep -q "CONVERGE RAN"'
check "did NOT reload"             not_called "systemctl reload app"
check "said why"                   grep -qi "host-converge" "$T/out.txt"
reset_log; run_deploy
check "resumes once fixed"         called "systemctl reload app"

echo "18. deploy/cloudflare.json changing in the ff range dispatches cf-converge@app.service, --no-block"
mkdir -p "$WORK/deploy"
( cd "$WORK" || exit 1; echo '{"ssl_mode":"strict"}' > deploy/cloudflare.json; git add -A; git commit -qm "cf json"; git push -q origin master; git push -q origin master:refs/heads/ci-green )
reset_log; run_deploy
check "exit 0"                     [ "$(rc)" = 0 ]
check "dispatched"                 called "systemctl start --no-block cf-converge@app.service"

echo "19. an ordinary deploy that does not touch it never dispatches cf-converge"
push_commit c19
( cd "$WORK" || exit 1; git push -q origin master:refs/heads/ci-green )
reset_log; run_deploy
check "exit 0"                     [ "$(rc)" = 0 ]
check "not dispatched"             not_called "cf-converge@app.service"

echo
if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; else echo "all checks passed"; fi
exit $((fails > 0))
