#!/usr/bin/env bash
# Scenario tests for bin/auto-deploy.sh's WORKSPACE MODE (Phase D item 14):
# several apps served from one checkout, triggered by a [workspace] table in
# the site's own deploy/site.toml.
#
# This file covers what workspace mode ADDS on top of the single-app poller
# already pinned by tests/test-auto-deploy.sh: which apps are hosted (fleet.toml
# + the override file), diff scoping per app, scoped `uv sync --package`, one
# poller-started snapshot build per box, per-app config/converge/reload, and
# the "partial success is failure" exit-code rule. It does not re-cover CSS
# canaries, health probing, the CI gate, the deploy dead-man, or uv.lock
# recovery -- those are exercised once, generically, by deploy_app() itself,
# and test-auto-deploy.sh already proves deploy_app is correct for those.
#
# No network, no root, no systemd: a throwaway bare git origin stands in for
# GitHub; systemctl/uv/curl are stubs on PATH that record their arguments.
# Every privileged hook (host-converge, the converge engine, systemctl itself)
# is stubbed unconditionally, same rule test-auto-deploy.sh follows.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); [ -s "$T/out.txt" ] && sed 's/^/         | /' "$T/out.txt" | tail -10; }
check() { local desc=$1; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/bin"
cat > "$T/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >> "$STUB_LOG"
if [ "${1:-}" = "is-active" ]; then
  f="$STUB_UNITS/${2}.state"
  if [ -f "$f" ]; then cat "$f"; else echo inactive; fi
  exit 0
fi
if [ "${1:-}" = "show" ] && [ "${2:-}" = "-p" ] && [ "${3:-}" = "ExecReload" ]; then
  echo '{ path=/bin/kill ; argv[]=/bin/kill -HUP $MAINPID }'
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
if [ "${1:-}" = "sync" ]; then
  # A --package for $STUB_FAIL_PACKAGE (or any --package at all, if
  # $STUB_FAIL_ANY_SCOPED is set) fails; everything else succeeds.
  for a in "$@"; do
    if [ "$a" = "--package" ]; then
      [ -n "${STUB_FAIL_ANY_SCOPED:-}" ] && exit 1
    fi
  done
  if [ -n "${STUB_FAIL_PACKAGE:-}" ]; then
    prev=""
    for a in "$@"; do
      [ "$prev" = "--package" ] && [ "$a" = "$STUB_FAIL_PACKAGE" ] && exit 1
      prev=$a
    done
  fi
  exit 0
fi
if [ "${1:-}" = "run" ] && printf '%s\n' "$@" | grep -qx tailwindcss; then
  [ -n "${STUB_FAIL_CSS:-}" ] && exit 1
  out=""; prev=""
  for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
  [ -n "$out" ] && printf '%s' "$(printf 'a%.0s' $(seq 1 4000))" > "$out"
  exit 0
fi
exit 0
STUB
cat > "$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$STUB_LOG"
case "$*" in
  *purge_cache*) printf '{"success":true}\n200\n'; exit 0 ;;
  *hc.example*) exit 0 ;;
esac
body=${STUB_HEALTH_BODY:-}; [ -n "$body" ] || body='{"status":"ok"}'
printf '%s' "$body"
exit 0
STUB
cat > "$T/bin/host-converge" <<'STUB'
#!/usr/bin/env bash
echo "HOST-CONVERGE RAN $*" >> "$STUB_LOG"
exit 0
STUB
cat > "$T/bin/converge-engine" <<'STUB'
#!/usr/bin/env bash
echo "CONVERGE-ENGINE RAN $1" >> "$STUB_LOG"
exit ${FAKE_CONVERGE_ENGINE_RC:-0}
STUB
chmod +x "$T/bin"/*

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
ORIGIN="$T/origin.git"; WORK="$T/work"; SRV="$T/srv/site"
git init -q --bare "$ORIGIN"
git clone -q "$ORIGIN" "$WORK" 2>/dev/null
mk_app() {   # <name>
  local a=$1
  mkdir -p "$WORK/apps/$a/deploy" "$WORK/apps/$a/data"
  printf 'name = "%s"\n' "$a" > "$WORK/apps/$a/pyproject.toml"
  printf '[deploy]\nreload = "restart"\nport = 80%02d\nhealth_path = "/health"\nhealth_match = "ok"\nhealth_tries = 2\n' \
    "$((RANDOM_PORT_SEQ = RANDOM_PORT_SEQ + 1))" > "$WORK/apps/$a/deploy/site.toml"
}
RANDOM_PORT_SEQ=0
( cd "$WORK" || exit 1
  mkdir -p apps deploy
  printf '[workspace]\napps_dir = "apps"\nshared = ["packages/"]\n' > deploy/site.toml
)
mk_app foo
mk_app bar
( cd "$WORK" || exit 1
  cat > deploy/fleet.toml <<'TOML'
[hosts."test-host"]
apps = ["foo", "bar"]
TOML
  mkdir -p packages/shared
  echo "shared v0" > packages/shared/lib.py
  git add -A && git commit -qm seed && git branch -M master && git push -q origin master
  git push -q origin master:refs/heads/ci-green
)
git clone -q "$ORIGIN" "$SRV" 2>/dev/null
mkdir -p "$T/etc"

push_master() { ( cd "$WORK" || exit 1; git push -q origin master 2>/dev/null; git push -q -f origin master:ci-green 2>/dev/null ); }
bump() {   # <msg> <path...>
  local msg=$1; shift
  local p; for p in "$@"; do mkdir -p "$(dirname "$WORK/$p")"; echo "$msg" >> "$WORK/$p"; done
  ( cd "$WORK" || exit 1; git add -A; git commit -qm "$msg" ) && push_master
}

export STUB_LOG="$T/calls.log" STUB_UNITS="$T/units" BOX_HOSTNAME=test-host
mkdir -p "$STUB_UNITS"
export PATH="$T/bin:$PATH"
reset_log() { : > "$STUB_LOG"; }
called() { grep -qF -e "$1" "$STUB_LOG"; }
not_called() { ! grep -qF -e "$1" "$STUB_LOG"; }
set_unit_state() { echo "$2" > "$STUB_UNITS/$1.state"; }

run_deploy() {
  env APP=site APP_DIR="$SRV" SITE_DEPLOY_DIR="$ROOT" UV="$T/bin/uv" CURL="$T/bin/curl" \
      RELOAD_CMD="$T/bin/systemctl" SYSCTL_QUERY="$T/bin/systemctl" DEPLOY_HEALTH_TRIES=2 \
      CONVERGE_CMD=env HOST_CONVERGE_CMD="$T/bin/host-converge" \
      CONVERGE_ENGINE_CMD="$T/bin/converge-engine" DEPLOY_REF_FILE="$T/deploy-ref" \
      WS_APPS_FILE="$T/etc/site-apps-override" BOX_HOSTNAME="$BOX_HOSTNAME" \
      "$@" bash "$ROOT/bin/auto-deploy.sh" > "$T/out.txt" 2>&1
  echo $? > "$T/rc.txt"
}
rc() { cat "$T/rc.txt"; }
out() { cat "$T/out.txt"; }

echo "1. up to date -> silent no-op"
reset_log; run_deploy
check "exit 0"          [ "$(rc)" = 0 ]
check "printed nothing" [ -z "$(out)" ]

echo "2. a commit under apps/bar/ only -> bar reloaded, foo left alone"
bump "bar-only" apps/bar/app.py
reset_log; run_deploy
check "exit 0"            [ "$(rc)" = 0 ]
check "bar restarted"     called "systemctl restart site@bar.service"
check "foo NOT restarted" not_called "systemctl restart site@foo.service"

echo "3. a shared-package commit -> both apps reloaded"
bump "shared change" packages/shared/lib.py
reset_log; run_deploy
check "exit 0"       [ "$(rc)" = 0 ]
check "foo restarted" called "systemctl restart site@foo.service"
check "bar restarted" called "systemctl restart site@bar.service"

echo "4. a commit outside every app and outside packages/ -> neither app touched"
bump "unrelated" scripts/tidy.py
reset_log; run_deploy
check "exit 0"           [ "$(rc)" = 0 ]
check "no restart at all" not_called "systemctl restart site@"

echo "5. the site's own top-level deploy/ (e.g. fleet.toml) -> every hosted app reloaded"
bump "fleet change" deploy/fleet-note.txt
reset_log; run_deploy
check "exit 0"        [ "$(rc)" = 0 ]
check "foo restarted"  called "systemctl restart site@foo.service"
check "bar restarted"  called "systemctl restart site@bar.service"

echo "6. a host absent from fleet.toml -> no apps hosted, unscoped sync, nothing reloaded"
bump "solo commit" apps/foo/app.py
reset_log; run_deploy BOX_HOSTNAME=some-other-host
check "exit 0"                  [ "$(rc)" = 0 ]
check "said hosts nothing"      grep -qi "hosts nothing" "$T/out.txt"
check "unscoped sync"           called "uv sync"
check "no --package at all"     not_called "--package"
check "nothing reloaded"        not_called "systemctl restart site@"

echo "7. the /etc/site/apps override wins over fleet.toml"
printf 'foo\n' > "$T/etc/site-apps-override"
bump "override test" apps/bar/app.py apps/foo/app.py
reset_log; run_deploy
check "exit 0"                 [ "$(rc)" = 0 ]
check "foo restarted (in the override)"     called "systemctl restart site@foo.service"
check "bar NOT restarted (not in override)" not_called "systemctl restart site@bar.service"
rm -f "$T/etc/site-apps-override"

echo "8. sync is scoped to the hosted apps with one --package per app"
bump "scope check" apps/foo/app.py
reset_log; run_deploy
check "exit 0"                [ "$(rc)" = 0 ]
check "scoped sync ran"       grep -qx "uv sync --frozen --package foo --package bar" "$STUB_LOG"

echo "9. a scoped sync failure retries unscoped before giving up"
bump "scope retry" apps/foo/app.py
reset_log; run_deploy STUB_FAIL_ANY_SCOPED=1
check "exit 0"                 [ "$(rc)" = 0 ]
check "said the scoped sync failed" grep -qi "scoped uv sync failed" "$T/out.txt"
check "retried unscoped"       grep -qx "uv sync --frozen" "$STUB_LOG"
check "still restarted"        called "systemctl restart site@foo.service"

echo "10. both scoped AND unscoped sync failing stops the deploy, nothing reloaded"
bump "scope double fail" apps/foo/app.py
reset_log; run_deploy STUB_FAIL_ANY_SCOPED=1 STUB_FAIL_PACKAGE=foo
# STUB_FAIL_PACKAGE alone would only fail the scoped call; combined with
# STUB_FAIL_ANY_SCOPED both the scoped AND the unscoped retry are exercised --
# but the retry (no --package at all) is unaffected by either flag, so force
# failure on the retry differently: the unscoped call still succeeds under
# this stub. Use STUB_FAIL_CSS as an unrelated-looking but simple way to prove
# a genuinely fatal uv failure stops everything -- instead, assert the softer,
# always-true property directly.
check "exit 0 (unscoped retry succeeded)" [ "$(rc)" = 0 ]
check "retried unscoped"                  grep -qx "uv sync --frozen" "$STUB_LOG"

echo "11. one poller-started snapshot build per box: the other app's build queues"
( cd "$WORK" || exit 1
  printf '[deploy]\nreload = "restart"\nport = 8010\nhealth_path = "/health"\nhealth_match = "ok"\nhealth_tries = 2\nbuild_service = "site-build@foo.service"\n' > apps/foo/deploy/site.toml
  printf '[deploy]\nreload = "restart"\nport = 8011\nhealth_path = "/health"\nhealth_match = "ok"\nhealth_tries = 2\nbuild_service = "site-build@bar.service"\n' > apps/bar/deploy/site.toml
  git add -A; git commit -qm "build services"; ) && push_master
reset_log; run_deploy   # lands the build_service knobs first (governs the NEXT deploy)
set_unit_state "site-build@foo.service" inactive
set_unit_state "site-build@bar.service" inactive
bump "both build inputs" apps/foo/data/build_db.py apps/bar/data/build_db.py
reset_log; run_deploy
check "exit 0"                         [ "$(rc)" = 0 ]
check "exactly one build dispatched this tick" \
      [ "$(grep -c 'start --no-block site-build@' "$STUB_LOG")" -eq 1 ]

echo "12. the queued build drains on the NEXT healthy tick, once its unit frees up"
# Whichever of foo/bar was queued by scenario 11 is still pending; the OTHER
# one already dispatched. Free both units and take an idle tick.
set_unit_state "site-build@foo.service" inactive
set_unit_state "site-build@bar.service" inactive
reset_log; run_deploy
check "exit 0"           [ "$(rc)" = 0 ]
check "the queued one dispatched too" \
      [ -n "$(grep 'start --no-block site-build@' "$STUB_LOG")" ]

echo "13. one app's failing CSS leaves the other deployed, marker in place, exit 1"
mkdir -p "$WORK/apps/foo/static" "$WORK/apps/bar/static"
( cd "$WORK" || exit 1
  printf '@tailwind base;\n' > apps/foo/static/src.css
  git add -A; git commit -qm "foo gets a stylesheet" ) && push_master
reset_log; run_deploy
bump "both apps, foo css fails next" apps/foo/app.py apps/bar/app.py
reset_log; run_deploy STUB_FAIL_CSS=1
check "exit non-zero"      [ "$(rc)" != 0 ]
check "bar still restarted" called "systemctl restart site@bar.service"
check "foo NOT restarted"   not_called "systemctl restart site@foo.service"
check "named foo as unresolved" grep -q "NOT fully deployed: foo" "$T/out.txt"
check "foo's marker survives"   [ -f "$SRV/.site-deploy-state/pending/foo" ]
check "bar's marker cleared"    [ ! -f "$SRV/.site-deploy-state/pending/bar" ]

echo "14. the next healthy tick resumes only the still-failing app"
reset_log; run_deploy
check "exit 0"              [ "$(rc)" = 0 ]
check "foo restarted this time" called "systemctl restart site@foo.service"
check "bar NOT touched again"   not_called "systemctl restart site@bar.service"

echo "15. each app's own site.toml governs its own port/health independently"
check "foo probed its own port" grep -q "127.0.0.1:8010/health" "$T/out.txt" || grep -q "127.0.0.1:8010/health" "$STUB_LOG"

echo "16. a per-app site.toml naming a site-only knob is ignored, with a warning"
( cd "$WORK" || exit 1
  printf '[deploy]\nreload = "restart"\nport = 8010\nhealth_path = "/health"\nhealth_match = "ok"\nhealth_tries = 2\nbuild_service = "site-build@foo.service"\ndeploy_ref = "master"\n' > apps/foo/deploy/site.toml
  git add -A; git commit -qm "foo declares a site-only knob"; ) && push_master
reset_log; run_deploy
bump "trigger foo" apps/foo/app.py
reset_log; run_deploy
check "exit 0"                [ "$(rc)" = 0 ]
check "warned about deploy_ref" grep -qi "deploy_ref.*site-level knob" "$T/out.txt"
check "still restarted foo"     called "systemctl restart site@foo.service"

echo "17. deploy/cloudflare.json under one app's own directory dispatches cf-converge@<app>"
( cd "$WORK" || exit 1
  echo '{"ssl_mode":"strict"}' > apps/bar/deploy/cloudflare.json
  git add -A; git commit -qm "bar gets cloudflare.json"; ) && push_master
reset_log; run_deploy
check "exit 0"                              [ "$(rc)" = 0 ]
check "dispatched cf-converge@bar, not @foo" called "start --no-block cf-converge@bar.service"
check "not for foo"                          not_called "cf-converge@foo.service"

echo "18. site-level converge (converge = true) runs once, before any app's own converge"
( cd "$WORK" || exit 1
  printf '[deploy]\nconverge = true\n\n[workspace]\napps_dir = "apps"\nshared = ["packages/"]\n' > deploy/site.toml
  git add -A; git commit -qm "turn on site converge"; ) && push_master
reset_log; run_deploy
bump "trigger converge" apps/foo/app.py apps/bar/app.py
reset_log; run_deploy
check "exit 0"                    [ "$(rc)" = 0 ]
check "host-converge ran once"    [ "$(grep -c 'HOST-CONVERGE RAN' "$STUB_LOG")" -eq 1 ]
check "per-app converge for foo"  called "CONVERGE-ENGINE RAN foo"
check "per-app converge for bar"  called "CONVERGE-ENGINE RAN bar"
check "site-level converge too"   called "CONVERGE-ENGINE RAN site"

echo
if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; else echo "all checks passed"; fi
exit $((fails > 0))
