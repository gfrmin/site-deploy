#!/usr/bin/env bash
# Scenario tests for bin/host-converge.sh: the box below the app converges too.
#
# No root, no systemd, no apt: HOST_ROOT= points every FILE path at a sandbox,
# and `systemctl`, `apt-get`, `dpkg-query`, `sysctl`, `swapon`, `fallocate`,
# `mkswap`, `visudo` are stubs on PATH that record their calls and keep state
# (`enable` marks a unit enabled, `enable --now` also active), so a run sees
# what the previous run left behind. Runs continue from each other.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); [ -s "$T/out.txt" ] && sed 's/^/         | /' "$T/out.txt" | tail -8; }
check() { local desc=$1; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }

T=$(mktemp -d); export T
# KEEP_SANDBOX=1 leaves the sandbox behind (path printed at the end) for a look
# at $T/calls.log and $T/units after a failing run.
if [ -n "${KEEP_SANDBOX:-}" ]; then trap 'echo "sandbox kept at $T"' EXIT; else trap 'rm -rf "$T"' EXIT; fi
export STUB_LOG="$T/calls.log" STUB_UNITS="$T/units"
HR="$T/root"; export HR
mkdir -p "$T/bin" "$STUB_UNITS" "$HR/etc/systemd/system" "$HR/etc/sudoers.d" "$HR/etc/app" \
         "$HR/srv/app/deploy" "$HR/usr/lib/systemd/system" "$HR/etc/fstab.d"
printf '/dev/data /mnt/data ext4 defaults 0 2' > "$HR/etc/fstab"    # no trailing newline, on purpose
ln -s "$ROOT" "$HR/srv/site-deploy"
# The app's env files, with only names that matter here.
printf 'DEPLOY_RELOAD=reload\n' > "$HR/etc/app/env"

cat > "$T/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >> "$STUB_LOG"
u=""; for a in "$@"; do case $a in -*) ;; is-*|enable|disable|start|stop|restart|daemon-reload|cat|show) ;; *) u=$a ;; esac; done
case "$1" in
  is-enabled) [ -e "$STUB_UNITS/$u.enabled" ]; exit $? ;;
  is-active)  [ -e "$STUB_UNITS/$u.active" ]; exit $? ;;
  enable)     touch "$STUB_UNITS/$u.enabled"; case " $* " in *" --now "*) touch "$STUB_UNITS/$u.active";; esac ;;
  disable)    rm -f "$STUB_UNITS/$u.enabled"; case " $* " in *" --now "*) rm -f "$STUB_UNITS/$u.active";; esac ;;
  start)      touch "$STUB_UNITS/$u.active" ;;
  stop)       rm -f "$STUB_UNITS/$u.active" ;;
  restart)    [ -n "${STUB_FAIL_RESTART:-}" ] && exit 1; touch "$STUB_UNITS/$u.active" ;;
  cat)        [ -e "$STUB_UNITS/$u.exists" ] || { echo "No files found for $u." >&2; exit 1; } ;;
  *) : ;;
esac
exit 0
STUB
cat > "$T/bin/apt-get" <<'STUB'
#!/usr/bin/env bash
echo "apt-get $*" >> "$STUB_LOG"
[ -n "${STUB_FAIL_APT:-}" ] && exit 100
for a in "$@"; do case $a in -*|install|update) ;; *) touch "$STUB_UNITS/pkg-$a" ;; esac; done
exit 0
STUB
cat > "$T/bin/dpkg-query" <<'STUB'
#!/usr/bin/env bash
# dpkg-query -W -f='${Status}' <pkg>
pkg=${*: -1}
if [ -e "$STUB_UNITS/pkg-$pkg" ]; then echo "install ok installed"; exit 0; fi
echo "dpkg-query: no packages found matching $pkg" >&2; exit 1
STUB
for s in sysctl swapon fallocate mkswap dd; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "$STUB_LOG"\n' "$s" > "$T/bin/$s"
done
# swapon --show=NAME --noheadings answers from state; `swapon /swapfile` records it
cat > "$T/bin/swapon" <<'STUB'
#!/usr/bin/env bash
echo "swapon $*" >> "$STUB_LOG"
case "$*" in *--show*) [ -e "$STUB_UNITS/swap" ] && echo /swapfile; exit 0 ;; esac
touch "$STUB_UNITS/swap"; exit 0
STUB
cat > "$T/bin/fallocate" <<'STUB'
#!/usr/bin/env bash
echo "fallocate $*" >> "$STUB_LOG"; : > "${*: -1}"; exit 0
STUB
cat > "$T/bin/visudo" <<'STUB'
#!/usr/bin/env bash
echo "visudo $*" >> "$STUB_LOG"
[ -n "${STUB_FAIL_VISUDO:-}" ] && exit 1
exit 0
STUB
chmod +x "$T/bin"/*; export PATH="$T/bin:$PATH"

reset_log() { : > "$STUB_LOG"; }
called() { grep -qF -e "$1" "$STUB_LOG"; }
not_called() { ! grep -qF -e "$1" "$STUB_LOG"; }
run() { env HOST_ROOT="$HR" "$@" bash "$ROOT/bin/host-converge.sh" app > "$T/out.txt" 2>&1; echo $? > "$T/rc.txt"; }
rc() { cat "$T/rc.txt"; }
out() { cat "$T/out.txt"; }

echo "1. a fresh box: everything derivable is derived"
reset_log; run
check "exit 0"                          [ "$(rc)" = 0 ]
check "toolkit units installed"         [ -f "$HR/etc/systemd/system/site-deploy@.service" ]
check "probe units installed"           [ -f "$HR/etc/systemd/system/site-probe@.timer" ]
check "daemon-reloaded"                 called "systemctl daemon-reload"
check "sudoers written"                 [ -f "$HR/etc/sudoers.d/app-deploy" ]
check "sudoers validated first"         called "visudo -cf"
check "grants reload AND restart"       bash -c 'grep -q "systemctl reload app" "$HR/etc/sudoers.d/app-deploy" && grep -q "systemctl restart app" "$HR/etc/sudoers.d/app-deploy"'
check "grants host-converge"            grep -q "host-converge.sh app" "$HR/etc/sudoers.d/app-deploy"
check "journald capped"                 grep -q "SystemMaxUse" "$HR/etc/systemd/journald.conf.d/site-deploy.conf"
check "needrestart exempts batch units" grep -q 'qr(^app-)' "$HR/etc/needrestart/conf.d/site-deploy.conf"
check "unattended upgrades on"          grep -q 'Unattended-Upgrade "1"' "$HR/etc/apt/apt.conf.d/20auto-upgrades"
check "swapfile created"                called "fallocate"
check "swap enabled"                    called "swapon $HR/swapfile"
check "fstab entry"                     grep -q '^/swapfile none swap' "$HR/etc/fstab"
check "swappiness applied"              called "sysctl"
check "missing packages installed"      called "apt-get install"
check "update timer enabled"            [ -e "$STUB_UNITS/site-deploy-update.timer.enabled" ]
check "app deploy timer enabled"        [ -e "$STUB_UNITS/site-deploy@app.timer.enabled" ]
check "probe NOT armed (no env)"        [ ! -e "$STUB_UNITS/site-probe@app.timer.enabled" ]
check "said unprobed"                   grep -qi "UNPROBED" "$T/out.txt"
check "no caddy drop-in (no caddy)"     [ ! -e "$HR/etc/systemd/system/caddy.service.d/site-deploy.conf" ]

echo "2. re-run with nothing drifted: silent, idempotent"
reset_log; run
check "exit 0"                          [ "$(rc)" = 0 ]
check "printed only the standing nags"  bash -c '[ "$(grep -vcE "UNPROBED|UNMONITORED" "$T/out.txt")" = 0 ]'
check "no daemon-reload"                not_called "daemon-reload"
check "no apt-get install"              not_called "apt-get install"
check "no swap work"                    not_called "fallocate"

echo "3. a toolkit unit drifts on the box: reinstalled; a changed active timer is restarted"
touch "$STUB_UNITS/site-deploy-update.timer.active"
echo "# drift" >> "$HR/etc/systemd/system/site-deploy-update.timer"
reset_log; run
check "reinstalled"                     bash -c '! grep -q drift "$HR/etc/systemd/system/site-deploy-update.timer"'
check "said so"                         grep -q "site-deploy-update.timer" "$T/out.txt"
check "daemon-reloaded"                 called "daemon-reload"
check "timer restarted"                 called "systemctl restart site-deploy-update.timer"

echo "4. a changed WORK timer an operator STOPPED stays stopped (pinning the toolkit through an incident)"
rm -f "$STUB_UNITS/site-deploy-update.timer.active"
echo "# drift" >> "$HR/etc/systemd/system/site-deploy-update.timer"
reset_log; run
check "not restarted"                   not_called "systemctl restart site-deploy-update.timer"
touch "$STUB_UNITS/site-deploy-update.timer.active"

echo "5. the probe env pair appears -> site-probe@app.timer armed; disappears -> disarmed"
printf 'PROBE_URL=https://x/health\nHEALTHCHECKS_PROBE_URL=https://hc/x\n' >> "$HR/etc/app/env"
reset_log; run
check "armed"                           [ -e "$STUB_UNITS/site-probe@app.timer.active" ]
check "said so"                         grep -q "site-probe@app.timer" "$T/out.txt"
reset_log; run
check "idempotent"                      not_called "systemctl enable"
rm -f "$STUB_UNITS/site-probe@app.timer.active"; reset_log; run   # an operator stopped the ALARM timer
check "alarm timer re-armed"            [ -e "$STUB_UNITS/site-probe@app.timer.active" ]
sed -i '/PROBE_URL/d' "$HR/etc/app/env"; reset_log; run
check "disarmed"                        [ ! -e "$STUB_UNITS/site-probe@app.timer.enabled" ]
check "nagged"                          grep -qi "UNPROBED" "$T/out.txt"

echo "6. ops-env with a key and a tag -> checks-armed timer armed; gone -> disarmed"
printf 'HEALTHCHECKS_API_KEY=k\nHEALTHCHECKS_SWEEP_TAG=fleet\n' > "$HR/etc/app/ops-env"
reset_log; run
check "armed"                           [ -e "$STUB_UNITS/site-checks-armed@app.timer.active" ]
rm "$HR/etc/app/ops-env"; reset_log; run
check "disarmed"                        [ ! -e "$STUB_UNITS/site-checks-armed@app.timer.enabled" ]

echo "6b. cf-converge: a sudoers grant always exists; cloudflare.json + a token arms cf-drift@app.timer"
check "cf-converge start grant present" grep -q "cf-converge@app.service" "$HR/etc/sudoers.d/app-deploy"
check "cf-drift NOT armed (no cloudflare.json)" [ ! -e "$STUB_UNITS/cf-drift@app.timer.enabled" ]
: > "$HR/srv/app/deploy/cloudflare.json"
reset_log; run
check "still not armed (no token)"      [ ! -e "$STUB_UNITS/cf-drift@app.timer.enabled" ]
check "said not converged"              grep -qi "NOT CONVERGED" "$T/out.txt"
echo "CF_CONFIG_TOKEN=t" > "$HR/etc/app/cf-env"
reset_log; run
check "armed"                           [ -e "$STUB_UNITS/cf-drift@app.timer.active" ]
rm "$HR/srv/app/deploy/cloudflare.json" "$HR/etc/app/cf-env"; reset_log; run
check "disarmed once cloudflare.json is gone" [ ! -e "$STUB_UNITS/cf-drift@app.timer.enabled" ]

echo "6c. backup: backup-producer.sh + BACKUP_AGE_RECIPIENT/BACKUP_RCLONE_DEST arms site-backup@app.timer"
check "not armed (no producer)"        [ ! -e "$STUB_UNITS/site-backup@app.timer.enabled" ]
: > "$HR/srv/app/deploy/backup-producer.sh"
reset_log; run
check "still not armed (no creds)"     [ ! -e "$STUB_UNITS/site-backup@app.timer.enabled" ]
check "said not backed up"             grep -qi "NOT BACKED UP" "$T/out.txt"
printf 'BACKUP_AGE_RECIPIENT=age1x\nBACKUP_RCLONE_DEST=r:b\n' > "$HR/etc/app/backup-env"
reset_log; run
check "armed"                          [ -e "$STUB_UNITS/site-backup@app.timer.active" ]
rm "$HR/srv/app/deploy/backup-producer.sh" "$HR/etc/app/backup-env"; reset_log; run
check "disarmed once producer is gone" [ ! -e "$STUB_UNITS/site-backup@app.timer.enabled" ]

echo "7. a Caddy unit exists -> the restart+memory drop-in is installed"
touch "$STUB_UNITS/caddy.service.exists"
reset_log; run
check "drop-in installed"               grep -q "Restart=always" "$HR/etc/systemd/system/caddy.service.d/site-deploy.conf"
check "memory cap present"              grep -q "MemoryMax=" "$HR/etc/systemd/system/caddy.service.d/site-deploy.conf"
check "daemon-reloaded"                 called "daemon-reload"
reset_log; run
check "idempotent"                      not_called "daemon-reload"

echo "8. the app declares extra packages -> installed; already-installed ones are not re-requested"
printf 'libgomp1\ncurl\n' > "$HR/srv/app/deploy/packages.txt"
touch "$STUB_UNITS/pkg-curl"
reset_log; run
check "installed the missing one"       called "apt-get install"
check "named libgomp1"                  bash -c 'grep "apt-get install" "$STUB_LOG" | grep -q libgomp1'
check "not curl"                        bash -c '! grep "apt-get install" "$STUB_LOG" | grep -q " curl"'

echo "9. a step fails -> counted, the rest still runs, one greppable line, exit 1"
echo "# drift" >> "$HR/etc/systemd/system/site-probe@.service"
reset_log; run STUB_FAIL_VISUDO=1
check "exit 1"                          [ "$(rc)" = 1 ]
check "one greppable line"              grep -q "HOST-CONVERGE FAILED" "$T/out.txt"
check "named the step"                  grep -qi "sudoers" "$T/out.txt"
check "later work still happened"       bash -c '! grep -q drift "$HR/etc/systemd/system/site-probe@.service"'
check "sudoers left untouched"          grep -q "systemctl reload app" "$HR/etc/sudoers.d/app-deploy"

echo "10. apt failing is counted too"
printf 'libgomp1\ncurl\nnewpkg\n' > "$HR/srv/app/deploy/packages.txt"
reset_log; run STUB_FAIL_APT=1
check "exit 1"                          [ "$(rc)" = 1 ]
check "named packages"                  grep -qi "packages" "$T/out.txt"

echo "11. with HOST_ROOT unset the constants are the production paths"
check "/etc and /srv literal"           grep -qF 'ROOT="${HOST_ROOT:-}"' "$ROOT/bin/host-converge.sh"

echo
if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; else echo "all checks passed"; fi
exit $((fails > 0))
