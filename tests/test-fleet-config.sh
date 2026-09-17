#!/usr/bin/env bash
# Scenario tests for bin/fleet-config.py.
#
# Pure stdlib tomllib, no network, no root, no privileged hook of any kind —
# nothing here needs a PATH stub or a HOST_ROOT sandbox.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SCRIPT="$ROOT/bin/fleet-config.py"

fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); }
check() { local desc=$1; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

run() {   # <path> <host>
  OUT=$(python3 "$SCRIPT" "$1" "$2" 2>"$T/err"); RC=$?
}

echo "1. a host with two apps: both printed, one per line"
cat > "$T/fleet.toml" <<'TOML'
[hosts."box-a"]
apps = ["foo", "bar"]
[hosts."box-b"]
apps = ["baz"]
TOML
run "$T/fleet.toml" box-a
check "exit 0"              [ "$RC" -eq 0 ]
check "both apps, in order" [ "$OUT" = "$(printf 'foo\nbar')" ]

echo "2. a host absent from the file: nothing printed, exit 0 (not an error)"
run "$T/fleet.toml" box-c
check "exit 0"               [ "$RC" -eq 0 ]
check "printed nothing"      [ -z "$OUT" ]

echo "3. no fleet.toml at all: nothing printed, exit 0 (not every site is workspace-hosted)"
run "$T/does-not-exist.toml" box-a
check "exit 0"                [ "$RC" -eq 0 ]
check "printed nothing"       [ -z "$OUT" ]

echo "4. exact hostname match only — no fuzzy fallback"
# The tailnet name and \`hostname\` can differ, and two app names can be one
# letter-order apart; a substring or prefix match would silently pick the
# wrong host's app list.
cat > "$T/fleet2.toml" <<'TOML'
[hosts."foo-web"]
apps = ["foo"]
[hosts."bar-web"]
apps = ["bar"]
TOML
run "$T/fleet2.toml" foo-web-1
check "exit 0"                    [ "$RC" -eq 0 ]
check "no fuzzy match"            [ -z "$OUT" ]
run "$T/fleet2.toml" foo-web
check "the exact name matches"    [ "$OUT" = "foo" ]

echo "5. a host with no apps key at all: nothing printed, exit 0"
cat > "$T/fleet3.toml" <<'TOML'
[hosts."empty-box"]
roles = ["backup-state"]
TOML
run "$T/fleet3.toml" empty-box
check "exit 0"          [ "$RC" -eq 0 ]
check "printed nothing" [ -z "$OUT" ]

echo "6. a malformed TOML file exits 1 with a reason on stderr, NEVER read as 'hosts nothing'"
printf '[hosts\napps = ' > "$T/broken.toml"
run "$T/broken.toml" box-a
check "exit 1 (not 0 — malformed must never look empty)" [ "$RC" -eq 1 ]
check "printed nothing to stdout"                          [ -z "$OUT" ]
check "said why on stderr"                                  [ -s "$T/err" ]

echo "7. 'hosts' present but not a table: exit 1, not a silent empty list"
printf 'hosts = "not-a-table"\n' > "$T/badhosts.toml"
run "$T/badhosts.toml" box-a
check "exit 1"        [ "$RC" -eq 1 ]
check "said why"       [ -s "$T/err" ]

echo "8. apps present but not a list of strings: exit 1, not a garbage app list"
cat > "$T/badapps.toml" <<'TOML'
[hosts."box-a"]
apps = ["foo", 7]
TOML
run "$T/badapps.toml" box-a
check "exit 1"   [ "$RC" -eq 1 ]
check "said why" [ -s "$T/err" ]

echo "9. usage: wrong argument count exits 2"
OUT=$(python3 "$SCRIPT" "$T/fleet.toml" 2>"$T/err"); RC=$?
check "exit 2" [ "$RC" -eq 2 ]

echo
if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; else echo "all checks passed"; fi
exit $((fails > 0))
