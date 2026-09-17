#!/usr/bin/env bash
# Scenario tests for bin/site-config.py's workspace-mode additions:
# --app-keys and the [workspace] table (Phase D item 14).
#
# The pre-existing [deploy] rendering is exercised end-to-end through
# tests/test-auto-deploy.sh (scenarios 10b/10d/13a/20/21); this file covers
# only what workspace mode adds, invoking the script directly.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SCRIPT="$ROOT/bin/site-config.py"

fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); }
check() { local desc=$1; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }
has() { grep -qF -e "$1" <<<"$OUT"; }
lacks() { ! grep -qF -e "$1" <<<"$OUT"; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

run() {   # [--app-keys] <path>
  OUT=$(python3 "$SCRIPT" "$@" 2>"$T/err"); RC=$?
}

echo "1. [workspace] renders WORKSPACE_APPS_DIR/SHARED/BUILD_INPUTS as newline-joined lists"
cat > "$T/site.toml" <<'TOML'
[workspace]
apps_dir     = "apps"
shared       = ["packages/", "shared/"]
build_inputs = ["packages/core/src/"]
TOML
run "$T/site.toml"
check "exit 0"                    [ "$RC" -eq 0 ]
check "apps_dir rendered"         has "export WORKSPACE_APPS_DIR=apps"
check "shared list is joined"     has "export WORKSPACE_SHARED="
check "shared has both entries"   bash -c "$OUT; [ \"\$WORKSPACE_SHARED\" = \$'packages/\\nshared/' ]"
check "build_inputs rendered"     has "export WORKSPACE_BUILD_INPUTS=packages/core/src/"

echo "2. [workspace] is absent from a plain [deploy]-only site.toml -- no export at all"
cat > "$T/site2.toml" <<'TOML'
[deploy]
reload = "reload"
TOML
run "$T/site2.toml"
check "exit 0"                     [ "$RC" -eq 0 ]
check "no WORKSPACE_ export"       lacks WORKSPACE_

echo "3. --app-keys renders the [deploy] table's per-app knobs normally"
cat > "$T/app.toml" <<'TOML'
[deploy]
reload  = "reload"
port    = 8000
service = "site@myapp.service"
TOML
run --app-keys "$T/app.toml"
check "exit 0"                     [ "$RC" -eq 0 ]
check "reload rendered"            has "export DEPLOY_RELOAD=reload"
check "port rendered"              has "export PORT=8000"
check "service rendered"           has "export DEPLOY_SERVICE=site@myapp.service"

echo "4. --app-keys drops the site-only knobs, and warns rather than silently ignoring"
cat > "$T/app2.toml" <<'TOML'
[deploy]
reload      = "reload"
deploy_ref  = "ci-green"
uv_args     = "--frozen"
converge    = true
tailwindcss_version = "4.3.3"
TOML
run --app-keys "$T/app2.toml"
check "exit 0"                       [ "$RC" -eq 0 ]
check "reload still rendered"        has "export DEPLOY_RELOAD=reload"
check "deploy_ref NOT rendered"      lacks "DEPLOY_REF="
check "uv_args NOT rendered"         lacks "DEPLOY_UV_ARGS="
check "converge NOT rendered"        lacks "DEPLOY_CONVERGE="
check "tailwindcss_version NOT rendered" lacks "TAILWINDCSS_VERSION="
check "warned about deploy_ref"      bash -c 'grep -qE "deploy_ref.*site-level knob" <<<"$1"' _ "$OUT"
check "warned about converge"        bash -c 'grep -qE "converge.*site-level knob" <<<"$1"' _ "$OUT"

echo "5. --app-keys never renders [workspace] either, even when the app file declares one"
cat > "$T/app3.toml" <<'TOML'
[deploy]
reload = "reload"
[workspace]
apps_dir = "apps"
TOML
run --app-keys "$T/app3.toml"
check "exit 0"                    [ "$RC" -eq 0 ]
check "no WORKSPACE_ export"      lacks WORKSPACE_

echo "6. without --app-keys, a site-level knob renders normally (the site's own site.toml)"
cat > "$T/site3.toml" <<'TOML'
[deploy]
reload     = "reload"
deploy_ref = "ci-green"
converge   = true
TOML
run "$T/site3.toml"
check "exit 0"                    [ "$RC" -eq 0 ]
check "deploy_ref rendered"       has "export DEPLOY_REF=ci-green"
check "converge rendered"         has "export DEPLOY_CONVERGE=True"
check "no site-only warning"      lacks "site-level knob"

echo
if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; else echo "all checks passed"; fi
exit $((fails > 0))
