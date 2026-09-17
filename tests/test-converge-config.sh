#!/usr/bin/env bash
# Scenario tests for bin/converge-config.py: the [converge] table reader
# bin/converge.sh builds its bash arrays from.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); }
check() { local desc=$1; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

run() { python3 "$ROOT/bin/converge-config.py" "$T/site.toml" > "$T/out.txt" 2> "$T/err.txt"; echo $? > "$T/rc.txt"; }
rc() { cat "$T/rc.txt"; }
out() { cat "$T/out.txt"; }
err() { cat "$T/err.txt"; }

echo "1. no site.toml at all: empty, exit 0"
rm -f "$T/site.toml"; run
check "exit 0"      [ "$(rc)" = 0 ]
check "no output"   [ ! -s "$T/out.txt" ]

echo "2. site.toml with no [converge] table: empty, exit 0"
printf '[deploy]\nreload = "reload"\n' > "$T/site.toml"; run
check "exit 0"      [ "$(rc)" = 0 ]
check "no output"   [ ! -s "$T/out.txt" ]

echo "3. a full, valid [converge] table"
cat > "$T/site.toml" <<'EOF'
[[converge.files]]
src = "deploy/app.service"
dst = "/etc/systemd/system/app.service"
apply = "daemon-reload"

[[converge.files]]
src = "deploy/Caddyfile"
dst = "/etc/caddy/Caddyfile"
validate = "caddy"
unit = "caddy"
apply = "reload"

[converge]
ensure_active = ["caddy"]
enable_timers = true
prune = true
EOF
run
check "exit 0"                 [ "$(rc)" = 0 ]
check "first file line"        grep -qxF $'FILE\x1fdeploy/app.service\x1f/etc/systemd/system/app.service\x1f\x1f\x1fdaemon-reload' "$T/out.txt"
check "second file line"       grep -qxF $'FILE\x1fdeploy/Caddyfile\x1f/etc/caddy/Caddyfile\x1fcaddy\x1fcaddy\x1freload' "$T/out.txt"
check "active line"            grep -qxF $'ACTIVE\x1fcaddy' "$T/out.txt"
check "enable_timers line"     grep -qxF $'ENABLE_TIMERS\x1f1' "$T/out.txt"
check "prune line"             grep -qxF $'PRUNE\x1f1' "$T/out.txt"

echo "4. a file missing 'src': malformed, exit 1"
printf '[[converge.files]]\ndst = "/etc/x"\n' > "$T/site.toml"; run
check "exit 1"      [ "$(rc)" = 1 ]
check "named src"   grep -q "'src'" "$T/err.txt"

echo "5. an unknown apply value: malformed, exit 1"
printf '[[converge.files]]\nsrc = "a"\ndst = "b"\napply = "reboot"\n' > "$T/site.toml"; run
check "exit 1"      [ "$(rc)" = 1 ]
check "named apply" grep -q "apply='reboot'" "$T/err.txt"

echo "6. apply=reload with no unit: malformed, exit 1"
printf '[[converge.files]]\nsrc = "a"\ndst = "b"\napply = "reload"\n' > "$T/site.toml"; run
check "exit 1"       [ "$(rc)" = 1 ]
check "named unit"   grep -q "requires 'unit'" "$T/err.txt"

echo "7. an unknown validate value: malformed, exit 1"
printf '[[converge.files]]\nsrc = "a"\ndst = "b"\nvalidate = "lint"\n' > "$T/site.toml"; run
check "exit 1"          [ "$(rc)" = 1 ]
check "named validate"  grep -q "validate='lint'" "$T/err.txt"

echo "8. a file with no apply at all is fine (installed, nothing reloaded)"
printf '[[converge.files]]\nsrc = "a"\ndst = "b"\n' > "$T/site.toml"; run
check "exit 0"    [ "$(rc)" = 0 ]
check "apply empty" grep -qxF $'FILE\x1fa\x1fb\x1f\x1f\x1f' "$T/out.txt"

echo "9. an invalid TOML file: exit 1, not exit 0 as if absent"
printf 'this is not toml [[[' > "$T/site.toml"; run
check "exit 1"    [ "$(rc)" = 1 ]

echo
if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; else echo "all checks passed"; fi
exit $((fails > 0))
