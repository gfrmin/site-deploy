#!/usr/bin/env bash
# Scenario tests for bin/converge.sh: the [converge]-table-driven engine.
#
# HOST_ROOT= points every FILE path at a sandbox; `systemctl`, `caddy`,
# `systemd-analyze`, `visudo` and `runuser` are stubs on PATH recording
# their calls and keeping unit state, the same idiom test-host-converge.sh
# uses. Runs continue from each other's state.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); [ -s "$T/out.txt" ] && sed 's/^/         | /' "$T/out.txt" | tail -10; }
check() { local desc=$1; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }

T=$(mktemp -d); export T
if [ -n "${KEEP_SANDBOX:-}" ]; then trap 'echo "sandbox kept at $T"' EXIT; else trap 'rm -rf "$T"' EXIT; fi
export STUB_LOG="$T/calls.log" STUB_UNITS="$T/units"
HR="$T/root"; export HR
mkdir -p "$T/bin" "$STUB_UNITS" "$HR/srv/app/deploy" "$HR/etc/systemd/system" "$HR/etc/caddy" "$HR/var/lib/app"
ln -s "$ROOT" "$HR/srv/site-deploy"

cat > "$T/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >> "$STUB_LOG"
if [ "$1" = show ]; then
  # systemctl show -p User --value <unit>
  echo "${STUB_CADDY_USER:-}"
  exit 0
fi
u=""; for a in "$@"; do case $a in -*) ;; is-*|enable|disable|start|stop|restart|reload|daemon-reload|show) ;; *) u=$a ;; esac; done
case "$1" in
  is-enabled) [ -e "$STUB_UNITS/$u.masked" ] && { echo masked; exit 0; }; [ -e "$STUB_UNITS/$u.enabled" ]; exit $? ;;
  is-active)  [ -e "$STUB_UNITS/$u.active" ]; exit $? ;;
  enable)     touch "$STUB_UNITS/$u.enabled"; case " $* " in *" --now "*) touch "$STUB_UNITS/$u.active";; esac ;;
  start)      [ -n "${STUB_FAIL_START:-}" ] && exit 1; touch "$STUB_UNITS/$u.active" ;;
  stop)       rm -f "$STUB_UNITS/$u.active" ;;
  restart)    [ -n "${STUB_FAIL_RESTART:-}" ] && exit 1; touch "$STUB_UNITS/$u.active"; touch "$STUB_UNITS/$u.restarted" ;;
  reload)     [ -n "${STUB_FAIL_RELOAD:-}" ] && exit 1; touch "$STUB_UNITS/$u.reloaded" ;;
  daemon-reload) [ -n "${STUB_FAIL_DAEMON_RELOAD:-}" ] && exit 1 ;;
  *) : ;;
esac
exit 0
STUB
cat > "$T/bin/caddy" <<'STUB'
#!/usr/bin/env bash
echo "caddy $*" >> "$STUB_LOG"
[ -n "${STUB_CADDY_VALID:-}" ] && exit 0
exit 1
STUB
cat > "$T/bin/systemd-analyze" <<'STUB'
#!/usr/bin/env bash
echo "systemd-analyze $*" >> "$STUB_LOG"
[ -n "${STUB_ANALYZE_VALID:-1}" ] && exit 0
exit 1
STUB
cat > "$T/bin/visudo" <<'STUB'
#!/usr/bin/env bash
echo "visudo $*" >> "$STUB_LOG"
[ -n "${STUB_VISUDO_VALID:-1}" ] && exit 0
exit 1
STUB
cat > "$T/bin/runuser" <<'STUB'
#!/usr/bin/env bash
echo "runuser $*" >> "$STUB_LOG"
shift 3   # -u <user> --
"$@"
STUB
chmod +x "$T/bin"/*
export PATH="$T/bin:$PATH"

reset_log() { : > "$STUB_LOG"; }
called() { grep -qF -e "$1" "$STUB_LOG"; }
not_called() { ! grep -qF -e "$1" "$STUB_LOG"; }
site_toml() { printf '%s\n' "$@" > "$HR/srv/app/deploy/site.toml"; }
run() { env HOST_ROOT="$HR" "$@" bash "$ROOT/bin/converge.sh" app > "$T/out.txt" 2>&1; echo $? > "$T/rc.txt"; }
rc() { cat "$T/rc.txt"; }

echo "1. no deploy/site.toml: no-op, exit 0"
reset_log; run
check "exit 0"          [ "$(rc)" = 0 ]
check "said so"         grep -qi "no deploy/site.toml" "$T/out.txt"

echo "2. site.toml with no [converge] table: no-op, exit 0"
site_toml '[deploy]' 'reload = "reload"'
reset_log; run
check "exit 0"          [ "$(rc)" = 0 ]
check "said so"         grep -qi "no \[converge\] table" "$T/out.txt"

echo "3. a malformed [converge] table: refuses outright"
site_toml '[[converge.files]]' 'dst = "/x"'
reset_log; run
check "exit 1"          [ "$(rc)" = 1 ]
check "said so"         grep -qi "malformed" "$T/out.txt"

echo "4. two daemon-reload files: both installed, daemon-reload runs exactly once"
mkdir -p "$HR/srv/app/deploy"
printf 'unit a\n' > "$HR/srv/app/deploy/a.service"
printf 'unit b\n' > "$HR/srv/app/deploy/b.service"
site_toml \
  '[[converge.files]]' 'src = "deploy/a.service"' 'dst = "/etc/systemd/system/a.service"' 'apply = "daemon-reload"' '' \
  '[[converge.files]]' 'src = "deploy/b.service"' 'dst = "/etc/systemd/system/b.service"' 'apply = "daemon-reload"'
reset_log; run
check "exit 0"                 [ "$(rc)" = 0 ]
check "a installed"            [ -f "$HR/etc/systemd/system/a.service" ]
check "b installed"            [ -f "$HR/etc/systemd/system/b.service" ]
check "daemon-reload once"     [ "$(grep -c 'daemon-reload' "$STUB_LOG")" = 1 ]

echo "5. re-run with nothing changed: silent, idempotent"
reset_log; run
check "exit 0"          [ "$(rc)" = 0 ]
check "no installs"     [ ! -s "$STUB_LOG" ]

echo "6. a reload file failing caddy validation is refused: not installed, no reload"
printf 'invalid {\n' > "$HR/srv/app/deploy/Caddyfile"
site_toml \
  '[[converge.files]]' 'src = "deploy/Caddyfile"' 'dst = "/etc/caddy/Caddyfile"' 'validate = "caddy"' 'unit = "caddy"' 'apply = "reload"'
reset_log; run
check "exit 1"               [ "$(rc)" = 1 ]
check "said so"              grep -qi "failed caddy validation" "$T/out.txt"
check "not installed"        [ ! -f "$HR/etc/caddy/Caddyfile" ]
check "no reload attempted"  not_called "systemctl reload caddy"

echo "7. a valid reload file: installed, unit reloaded, no .bak left behind"
touch "$STUB_UNITS/caddy.active"
reset_log; run STUB_CADDY_VALID=1
check "exit 0"          [ "$(rc)" = 0 ]
check "validated as root (no User=)" not_called "runuser"
check "installed"       [ -f "$HR/etc/caddy/Caddyfile" ]
check "reloaded"        called "systemctl reload caddy"
check "no .bak left"    [ ! -f "$HR/etc/caddy/Caddyfile.bak" ]

echo "7b. validate=caddy resolves the unit's User= and validates as that user"
printf 'v2 {\n}\n' > "$HR/srv/app/deploy/Caddyfile"
reset_log; run STUB_CADDY_VALID=1 STUB_CADDY_USER=caddy
check "exit 0"           [ "$(rc)" = 0 ]
check "ran as caddy"     called "runuser -u caddy --"

echo "8. a failed reload restores the previous file and retries the reload"
printf 'v3 {\n}\n' > "$HR/srv/app/deploy/Caddyfile"
reset_log; run STUB_CADDY_VALID=1 STUB_FAIL_RELOAD=1
check "exit 1"                 [ "$(rc)" = 1 ]
check "said FAILED"            grep -qi "reload FAILED" "$T/out.txt"
check "reload attempted twice" [ "$(grep -c 'systemctl reload caddy' "$STUB_LOG")" = 2 ]
check "restored the old file"  bash -c '! grep -q v3 "$HR/etc/caddy/Caddyfile"'

echo "9. ensure_active starts a unit that is down"
site_toml \
  '[converge]' 'ensure_active = ["caddy"]'
rm -f "$STUB_UNITS/caddy.active"
reset_log; run
check "exit 0"     [ "$(rc)" = 0 ]
check "started"    [ -e "$STUB_UNITS/caddy.active" ]
check "said so"    grep -qi "caddy is down -- starting it" "$T/out.txt"

echo "10. cold-start guard: a unit ensure_active just started skips its own reload this tick"
rm -f "$STUB_UNITS/caddy.active"
printf 'v4 {\n}\n' > "$HR/srv/app/deploy/Caddyfile"
site_toml \
  '[[converge.files]]' 'src = "deploy/Caddyfile"' 'dst = "/etc/caddy/Caddyfile"' 'validate = "caddy"' 'unit = "caddy"' 'apply = "reload"' '' \
  '[converge]' 'ensure_active = ["caddy"]'
reset_log; run STUB_CADDY_VALID=1
check "exit 0"              [ "$(rc)" = 0 ]
check "started"             called "systemctl start caddy"
check "never reloaded"      not_called "systemctl reload caddy"
check "said no reload needed" grep -qi "no reload needed" "$T/out.txt"

echo "11. apply=restart restarts the unit unconditionally on change"
printf 'unit c v1\n' > "$HR/srv/app/deploy/c.service"
site_toml \
  '[[converge.files]]' 'src = "deploy/c.service"' 'dst = "/etc/systemd/system/c.service"' 'unit = "c"' 'apply = "restart"'
reset_log; run
check "exit 0"       [ "$(rc)" = 0 ]
check "restarted"    [ -e "$STUB_UNITS/c.restarted" ]

echo "12. enable_timers: a declared timer is enabled and started if not already"
printf 'timer\n' > "$HR/srv/app/deploy/x.timer"
site_toml \
  '[[converge.files]]' 'src = "deploy/x.timer"' 'dst = "/etc/systemd/system/x.timer"' '' \
  '[converge]' 'enable_timers = true'
reset_log; run
check "exit 0"      [ "$(rc)" = 0 ]
check "enabled"     [ -e "$STUB_UNITS/x.timer.enabled" ]
check "active"      [ -e "$STUB_UNITS/x.timer.active" ]

echo "13. a masked unit is left alone by ensure_active and enable_timers alike"
touch "$STUB_UNITS/x.timer.masked"; rm -f "$STUB_UNITS/x.timer.enabled" "$STUB_UNITS/x.timer.active"
reset_log; run
check "exit 0"          [ "$(rc)" = 0 ]
check "still not enabled" [ ! -e "$STUB_UNITS/x.timer.enabled" ]
rm -f "$STUB_UNITS/x.timer.masked"

echo "14. prune: a file installed before but no longer declared is removed; a kept one survives"
site_toml \
  '[[converge.files]]' 'src = "deploy/x.timer"' 'dst = "/etc/systemd/system/x.timer"' '' \
  '[converge]' 'enable_timers = true' 'prune = true'
reset_log; run   # first run with prune=true: records the manifest, x.timer stays
check "x.timer kept"    [ -f "$HR/etc/systemd/system/x.timer" ]
site_toml \
  '[converge]' 'prune = true'   # x.timer no longer declared at all
reset_log; run
check "exit 0"          [ "$(rc)" = 0 ]
check "pruned"          [ ! -f "$HR/etc/systemd/system/x.timer" ]
check "said so"         grep -qi "pruned .*x.timer" "$T/out.txt"

echo "15. a declared src missing from the repo is a counted failure, not a silent skip"
site_toml \
  '[[converge.files]]' 'src = "deploy/does-not-exist.service"' 'dst = "/etc/systemd/system/nope.service"' 'apply = "daemon-reload"'
reset_log; run
check "exit 1"       [ "$(rc)" = 1 ]
check "said so"      grep -q "missing in repo" "$T/out.txt"
check "not installed" [ ! -f "$HR/etc/systemd/system/nope.service" ]

echo "16. a comment-only change to a systemd unit is installed but NOT reloaded/restarted"
printf 'unit a\n' > "$HR/srv/app/deploy/d.service"
site_toml \
  '[[converge.files]]' 'src = "deploy/d.service"' 'dst = "/etc/systemd/system/d.service"' 'unit = "d"' 'apply = "restart"'
reset_log; run
check "exit 0 (baseline restart)" [ "$(rc)" = 0 ]
check "restarted the baseline"    called "systemctl restart d"
printf 'unit a\n# just a comment\n\n' > "$HR/srv/app/deploy/d.service"
reset_log; run
check "exit 0"                    [ "$(rc)" = 0 ]
check "installed the new file"    grep -qF "$(cat "$HR/srv/app/deploy/d.service")" "$HR/etc/systemd/system/d.service"
check "said comment-only"         grep -qi "comments or blank" "$T/out.txt"
check "did NOT restart again"     not_called "systemctl restart d"

echo "17. a REAL directive change to the same unit restarts it"
printf 'unit a\nExtra=1\n' > "$HR/srv/app/deploy/d.service"
reset_log; run
check "exit 0"                    [ "$(rc)" = 0 ]
check "restarted (real change)"   called "systemctl restart d"

echo "18. apply=restart daemon-reloads BEFORE restarting, not only apply=daemon-reload files"
printf 'unit a\nExtra=2\n' > "$HR/srv/app/deploy/d.service"
reset_log; run
check "exit 0"                          [ "$(rc)" = 0 ]
check "daemon-reloaded"                 called "systemctl daemon-reload"
check "reload happens before restart"   bash -c '
  r=$(grep -n "daemon-reload" "$STUB_LOG" | head -1 | cut -d: -f1)
  s=$(grep -n "restart d$" "$STUB_LOG" | head -1 | cut -d: -f1)
  [ -n "$r" ] && [ -n "$s" ] && [ "$r" -lt "$s" ]'

echo "19. enable_timers: an ALREADY enabled+active timer whose file changed is restarted, not left alone"
printf 'timer x\n' > "$HR/srv/app/deploy/y.timer"
site_toml \
  '[[converge.files]]' 'src = "deploy/d.service"' 'dst = "/etc/systemd/system/d.service"' 'unit = "d"' 'apply = "restart"' '' \
  '[[converge.files]]' 'src = "deploy/y.timer"' 'dst = "/etc/systemd/system/y.timer"' '' \
  '[converge]' 'enable_timers = true'
reset_log; run
check "exit 0 (first arm)"        [ "$(rc)" = 0 ]
check "x armed"                   [ -e "$STUB_UNITS/y.timer.enabled" ] && [ -e "$STUB_UNITS/y.timer.active" ]
printf 'timer x\nOnCalendar=*-*-* 05:00:00\n' > "$HR/srv/app/deploy/y.timer"
reset_log; run
check "exit 0"                    [ "$(rc)" = 0 ]
check "restarted (schedule changed)" [ -e "$STUB_UNITS/y.timer.restarted" ]
rm -f "$STUB_UNITS/y.timer.restarted"
reset_log; run   # idle tick: nothing changed this time
check "exit 0"                    [ "$(rc)" = 0 ]
check "NOT restarted again"       [ ! -e "$STUB_UNITS/y.timer.restarted" ]

# ── the template-restart queue (workspace mode, Phase D item 14) ────────────
# A site-level [[converge.files]] entry can declare the TEMPLATE unit that
# every hosted app instantiates (e.g. site2@.service). systemctl cannot
# restart a bare template, so converge.sh queues a restart for each hosted
# app whose own service is an instance of it instead.
echo "workspace fixture: site2 hosting foo2 and bar2"
mkdir -p "$HR/srv/site2/apps/foo2/deploy" "$HR/srv/site2/apps/bar2/deploy" "$HR/srv/site2/deploy" \
         "$HR/var/lib/site-deploy/site2"
printf '[hosts."thehost"]\napps = ["foo2", "bar2"]\n' > "$HR/srv/site2/deploy/fleet.toml"
printf '[deploy]\nreload = "reload"\n' > "$HR/srv/site2/apps/foo2/deploy/site.toml"
printf '[deploy]\nreload = "reload"\nservice = "site2@custom-bar2.service"\n' > "$HR/srv/site2/apps/bar2/deploy/site.toml"
printf 'template v1\n' > "$HR/srv/site2/deploy/site2-app.service"
run2() { env HOST_ROOT="$HR" BOX_HOSTNAME=thehost bash "$ROOT/bin/converge.sh" site2 > "$T/out.txt" 2>&1; echo $? > "$T/rc.txt"; }

echo "20. a template unit's restart queues one marker per hosted app that instantiates it"
cat > "$HR/srv/site2/deploy/site.toml" <<'TOML'
[workspace]
apps_dir = "apps"

[[converge.files]]
src = "deploy/site2-app.service"
dst = "/etc/systemd/system/site2@.service"
unit = "site2@"
apply = "restart"
TOML
reset_log; run2
check "exit 0"                      [ "$(rc)" = 0 ]
check "installed the template file" [ -f "$HR/etc/systemd/system/site2@.service" ]
check "did NOT try to restart the bare template" not_called "systemctl restart site2@"
check "foo2 queued (default site2@foo2.service matches)" \
      [ "$(cat "$HR/var/lib/site-deploy/site2/pending/foo2")" = restart ]
check "bar2 queued too (its OWN declared service also matches)" \
      [ "$(cat "$HR/var/lib/site-deploy/site2/pending/bar2")" = restart ]
check "said so for foo2"            grep -q "foo2: restart queued (site2@ changed" "$T/out.txt"

echo "21. re-run with the template unchanged: no new markers, no restart, silent about it"
rm -f "$HR/var/lib/site-deploy/site2/pending/foo2" "$HR/var/lib/site-deploy/site2/pending/bar2"
reset_log; run2
check "exit 0"                [ "$(rc)" = 0 ]
check "no re-install"         not_called "installed deploy/site2-app.service"
check "nothing queued again"  [ ! -e "$HR/var/lib/site-deploy/site2/pending/foo2" ]

echo "22. a service that does not actually instantiate the template is not swept in"
printf '[deploy]\nreload = "reload"\nservice = "notsite2@bar2.service"\n' > "$HR/srv/site2/apps/bar2/deploy/site.toml"
echo "template v2" >> "$HR/srv/site2/deploy/site2-app.service"
reset_log; run2
check "exit 0"                 [ "$(rc)" = 0 ]
check "foo2 still queued"      [ "$(cat "$HR/var/lib/site-deploy/site2/pending/foo2")" = restart ]
check "bar2 NOT queued (its service does not instantiate site2@)" \
      [ ! -e "$HR/var/lib/site-deploy/site2/pending/bar2" ]
rm -f "$HR/var/lib/site-deploy/site2/pending/foo2"
printf '[deploy]\nreload = "reload"\nservice = "site2@custom-bar2.service"\n' > "$HR/srv/site2/apps/bar2/deploy/site.toml"

echo "23. apply = \"reload\" on a template is refused by converge-config.py, never attempted"
cat > "$HR/srv/site2/deploy/site.toml" <<'TOML'
[workspace]
apps_dir = "apps"

[[converge.files]]
src = "deploy/site2-app.service"
dst = "/etc/systemd/system/site2@.service"
unit = "site2@"
apply = "reload"
TOML
reset_log; run2
check "exit 1"                 [ "$(rc)" = 1 ]
check "named it a template"    grep -qi "template unit" "$T/out.txt"
check "did not install"        not_called "installed deploy/site2-app.service"

echo
if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; else echo "all checks passed"; fi
exit $((fails > 0))
