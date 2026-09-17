#!/usr/bin/env bash
# Scenario tests for lib/workspace.sh (Phase D item 14).
#
# No network, no root, no systemd — every function here is read-only (no
# mkdir, no writes), so there is nothing to sandbox beyond pointing the
# functions' file-path inputs (the override file, the fleet.toml, the srv
# checkout, the /srv root for ws_site_of) at throwaway fixtures.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
# shellcheck disable=SC1091
. "$ROOT/lib/workspace.sh"

fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); }
check() { local desc=$1; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }
not() { ! "$@"; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# --- ws_apps -------------------------------------------------------------
mkdir -p "$T/srv/site" "$T/etc"
export WS_APPS_FILE="$T/etc/site-apps-override"   # points ws_apps at a fixture, not /etc/site/apps

echo "1. no override, no fleet.toml -> hosts nothing, says so on stderr"
rm -f "$WS_APPS_FILE"
OUT=$(ws_apps "$T/srv/site" site 2>"$T/err"); RC=$?
check "exit 0"                [ "$RC" -eq 0 ]
check "printed nothing"       [ -z "$OUT" ]
check "said so on stderr"     grep -qi "hosting nothing" "$T/err"

echo "2. deploy/fleet.toml lists this host -> those apps, one per line"
mkdir -p "$T/srv/site/deploy"
cat > "$T/srv/site/deploy/fleet.toml" <<'TOML'
[hosts."test-host"]
apps = ["foo", "bar"]
TOML
OUT=$(BOX_HOSTNAME=test-host ws_apps "$T/srv/site" site 2>"$T/err"); RC=$?
check "exit 0"                 [ "$RC" -eq 0 ]
check "both apps"              [ "$OUT" = "$(printf 'foo\nbar')" ]
check "silent (no nag)"        [ -z "$(cat "$T/err")" ]

echo "3. this host is not in fleet.toml -> hosts nothing, says so every time"
OUT=$(BOX_HOSTNAME=other-host ws_apps "$T/srv/site" site 2>"$T/err"); RC=$?
check "exit 0"                 [ "$RC" -eq 0 ]
check "printed nothing"        [ -z "$OUT" ]
check "said so"                grep -qi "hosts nothing" "$T/err"

echo "4. the /etc/<site>/apps override wins over fleet.toml, and is nagged every tick"
printf 'baz  qux\n' > "$WS_APPS_FILE"
OUT=$(BOX_HOSTNAME=test-host ws_apps "$T/srv/site" site 2>"$T/err"); RC=$?
check "exit 0"                  [ "$RC" -eq 0 ]
check "override apps, whole-file split, not fleet.toml's" \
      [ "$OUT" = "$(printf 'baz\nqux')" ]
check "nagged about the override" grep -qi "overridden by" "$T/err"

echo "5. the override is read WHOLE, not line-by-line — an app on its own line is not lost"
# renavon's \`read -r -a APPS < file\` once stopped at the first newline and
# silently never deployed an app appended on its own line (bechirot).
printf 'foo\nbar\nbaz\n' > "$WS_APPS_FILE"
OUT=$(BOX_HOSTNAME=test-host ws_apps "$T/srv/site" site 2>/dev/null)
check "all three lines survive" [ "$OUT" = "$(printf 'foo\nbar\nbaz')" ]
rm -f "$WS_APPS_FILE"

echo "6. a malformed fleet.toml -> ws_apps fails LOUDLY, never silently 'hosts nothing'"
printf '[hosts\napps = ' > "$T/srv/site/deploy/fleet.toml"
OUT=$(BOX_HOSTNAME=test-host ws_apps "$T/srv/site" site 2>"$T/err"); RC=$?
check "non-zero exit"           [ "$RC" -ne 0 ]
check "printed nothing"         [ -z "$OUT" ]
check "said it is malformed"    grep -qi "malformed" "$T/err"
cat > "$T/srv/site/deploy/fleet.toml" <<'TOML'
[hosts."test-host"]
apps = ["foo"]
TOML

echo "7. fleet.toml lists this host with an EMPTY app list -> hosts nothing, says so"
cat > "$T/srv/site/deploy/fleet.toml" <<'TOML'
[hosts."test-host"]
apps = []
TOML
OUT=$(BOX_HOSTNAME=test-host ws_apps "$T/srv/site" site 2>"$T/err"); RC=$?
check "exit 0"                  [ "$RC" -eq 0 ]
check "printed nothing"         [ -z "$OUT" ]
check "said hosts nothing"      grep -qi "hosts nothing" "$T/err"

# --- ws_active ---------------------------------------------------------------
echo "7b. ws_active is false with no [workspace] table at all"
rm -rf "$T/srv/site3"; mkdir -p "$T/srv/site3/deploy"
printf '[deploy]\nreload = "reload"\n' > "$T/srv/site3/deploy/site.toml"
check "not active"       not ws_active "$T/srv/site3"

echo "7c. ws_active is true once [workspace] is declared, even with no keys"
printf '[workspace]\n' > "$T/srv/site3/deploy/site.toml"
check "active"            ws_active "$T/srv/site3"

echo "7d. ws_active is false with no deploy/site.toml at all"
rm -rf "$T/srv/site4"; mkdir -p "$T/srv/site4"
check "not active (no file)" not ws_active "$T/srv/site4"

# --- ws_apps_dir -----------------------------------------------------------
echo "8. ws_apps_dir defaults to 'apps' with no site.toml at all"
rm -rf "$T/srv/site2"; mkdir -p "$T/srv/site2"
check "default is apps" [ "$(ws_apps_dir "$T/srv/site2")" = apps ]

echo "9. ws_apps_dir reads [workspace] apps_dir from site.toml"
mkdir -p "$T/srv/site2/deploy"
printf '[workspace]\napps_dir = "services"\n' > "$T/srv/site2/deploy/site.toml"
check "custom apps_dir" [ "$(ws_apps_dir "$T/srv/site2")" = services ]

echo "10. ws_apps_dir extracts exactly WORKSPACE_APPS_DIR, ignoring every other export line"
# site.toml's [deploy] table renders its own export lines first; ws_apps_dir
# must return the workspace value regardless of what else is in there, and
# a value containing shell metacharacters must come back as an inert string
# (sed-extraction only, matching host-converge.sh's own DEPLOY_BUILD_SERVICE
# read — never eval a whole TOML render for a single scalar).
printf '[deploy]\nport = 9999\nreload = "restart"\n[workspace]\napps_dir = "apps; touch %s/PWNED"\n' "$T" > "$T/srv/site2/deploy/site.toml"
out=$(ws_apps_dir "$T/srv/site2")
check "returned the literal apps_dir string, unaffected by [deploy]" \
      [ "$out" = "apps; touch $T/PWNED" ]
check "did NOT execute the metacharacters"   [ ! -e "$T/PWNED" ]

# --- ws_site_of --------------------------------------------------------------
echo "11. a /srv/<name> symlink into a site's apps_dir names that site"
mkdir -p "$T/root/srv/theSite/apps/foo"
ln -s "$T/root/srv/theSite/apps/foo" "$T/root/srv/foo"
check "resolved to theSite" [ "$(ws_site_of "$T/root" foo)" = theSite ]

echo "12. no symlink at all -> the name is its own site (single-app shape)"
mkdir -p "$T/root/srv/standalone"
check "is its own site" [ "$(ws_site_of "$T/root" standalone)" = standalone ]

echo "13. a symlink that does NOT point into any site's /srv/<site>/... -> its own name"
ln -s /somewhere/else "$T/root/srv/weird"
check "falls back to its own name" [ "$(ws_site_of "$T/root" weird)" = weird ]

echo
if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; else echo "all checks passed"; fi
exit $((fails > 0))
