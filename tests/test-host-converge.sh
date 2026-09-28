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
# Hermetic by default: a dev box may have a real `caddy` user, and chown to it
# needs root. Scenario 7b opts in with CADDY_USER=<the test's own user>.
export CADDY_USER=no-such-user-here
# stat reports STUB_STAT_OWNER for %U (a root-owned log without being root), the real answer otherwise.
cat > "$T/bin/stat" <<'STUB'
#!/usr/bin/env bash
case " $* " in *" -c %U "*) is_owner=1 ;; esac
[ -n "${is_owner:-}" ] && [ -n "${STUB_STAT_OWNER:-}" ] && { echo "$STUB_STAT_OWNER"; exit 0; }
exec /usr/bin/stat "$@"
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
# Exact, not a substring: "systemctl reload app" also matches "systemctl reload app.service",
# which is how a grant for the wrong unit name went unnoticed (sudo matches literally).
check "grants reload AND restart of the unit the poller reloads (app.service)" \
  grep -qF "NOPASSWD: /usr/bin/systemctl reload app.service, /usr/bin/systemctl restart app.service" "$HR/etc/sudoers.d/app-deploy"
check "no grant for the bare name the poller never runs" \
  bash -c '! grep -qE "systemctl (reload|restart) app(,|$)" "$HR/etc/sudoers.d/app-deploy"'
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

echo "7b. the app's caddy access log is pre-created caddy-owned, and repaired if root-owned"
ME=$(id -un)
reset_log; run CADDY_USER="$ME"
check "exit 0"                          [ "$(rc)" = 0 ]
check "log created"                     [ -f "$HR/var/log/caddy/app.access.log" ]
check "owned by the caddy user"         [ "$(stat -c %U "$HR/var/log/caddy/app.access.log")" = "$ME" ]
check "said so"                         grep -q "created .*app.access.log" "$T/out.txt"
reset_log; run CADDY_USER="$ME"
check "idempotent: silent"              bash -c '! grep -q "access.log" "$T/out.txt"'
echo "some lines" > "$HR/var/log/caddy/app.access.log"
reset_log; run CADDY_USER="$ME" STUB_STAT_OWNER=root
check "root-owned: repaired"            grep -q "repaired .*app.access.log: was owned by root" "$T/out.txt"
check "contents kept"                   grep -q "some lines" "$HR/var/log/caddy/app.access.log"
reset_log; run CADDY_USER=no-such-user-here
check "no caddy user: nothing attempted" bash -c '! grep -q "access.log" "$T/out.txt"'

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
check "sudoers left untouched"          grep -qF "systemctl reload app.service," "$HR/etc/sudoers.d/app-deploy"

echo "10. apt failing is counted too"
printf 'libgomp1\ncurl\nnewpkg\n' > "$HR/srv/app/deploy/packages.txt"
reset_log; run STUB_FAIL_APT=1
check "exit 1"                          [ "$(rc)" = 1 ]
check "named packages"                  grep -qi "packages" "$T/out.txt"

echo "10b. site.toml \`service\` names the unit -> the grant follows it (bare name here)"
printf '[deploy]\nreload = "reload"\nservice = "app"\n' > "$HR/srv/app/deploy/site.toml"
reset_log; run
check "grants the declared bare unit"   grep -qF "NOPASSWD: /usr/bin/systemctl reload app, /usr/bin/systemctl restart app" "$HR/etc/sudoers.d/app-deploy"
check "and not the .service default"    bash -c '! grep -qF "systemctl reload app.service" "$HR/etc/sudoers.d/app-deploy"'
rm -f "$HR/srv/app/deploy/site.toml"
reset_log; run
check "default restored without it"     grep -qF "systemctl reload app.service," "$HR/etc/sudoers.d/app-deploy"

echo "11. with HOST_ROOT unset the constants are the production paths"
check "/etc and /srv literal"           grep -qF 'ROOT="${HOST_ROOT:-}"' "$ROOT/bin/host-converge.sh"

# ── workspace mode (Phase D item 14): several apps out of one checkout ──────
echo "workspace fixture: a site hosting foo and bar"
mkdir -p "$HR/srv/site/apps/foo/deploy" "$HR/srv/site/apps/bar/deploy" "$HR/srv/site/deploy" \
         "$HR/etc/foo" "$HR/etc/bar"
printf '[workspace]\napps_dir = "apps"\n' > "$HR/srv/site/deploy/site.toml"
printf '[hosts."the-host"]\napps = ["foo", "bar"]\n' > "$HR/srv/site/deploy/fleet.toml"
printf '[deploy]\nreload = "reload"\n' > "$HR/srv/site/apps/foo/deploy/site.toml"
printf '[deploy]\nreload = "reload"\nbuild_service = "site-build@bar.service"\n' > "$HR/srv/site/apps/bar/deploy/site.toml"
run_ws() { env HOST_ROOT="$HR" BOX_HOSTNAME=the-host bash "$ROOT/bin/host-converge.sh" site > "$T/out.txt" 2>&1; echo $? > "$T/rc.txt"; }

echo "12. a fresh workspace box: a symlink + /var/lib per app, no name collision"
reset_log; run_ws
check "exit 0"                       [ "$(rc)" = 0 ]
check "foo symlinked"                [ -L "$HR/srv/foo" ]
check "foo points at the right dir"  [ "$(readlink "$HR/srv/foo")" = "$HR/srv/site/apps/foo" ]
check "bar symlinked"                [ -L "$HR/srv/bar" ]
check "/var/lib/foo created"         [ -d "$HR/var/lib/foo" ]
check "/var/lib/bar created"         [ -d "$HR/var/lib/bar" ]
check "site poller timer armed"      [ -e "$STUB_UNITS/site-deploy@site.timer.enabled" ]
check "NEVER a per-app deploy timer" [ ! -e "$STUB_UNITS/site-deploy@foo.timer.enabled" ]

echo "13. re-run: silent identity (idempotent, no re-link, no re-mkdir noise)"
reset_log; run_ws
check "exit 0"           [ "$(rc)" = 0 ]
check "no re-creation logged" not_called "created /srv/foo"

echo "14. the probe/checks-armed drop-ins carry User=site (the site's service user)"
check "foo probe drop-in exists"     [ -f "$HR/etc/systemd/system/site-probe@foo.service.d/site-deploy.conf" ]
check "it names the site as User="   grep -qx "User=site" "$HR/etc/systemd/system/site-probe@foo.service.d/site-deploy.conf"
check "checks-armed drop-in too"     grep -qx "User=site" "$HR/etc/systemd/system/site-checks-armed@foo.service.d/site-deploy.conf"

echo "15. per-app sudoers: each app's OWN unit name, default site@<app>.service"
check "foo reload/restart grant"     grep -q "systemctl reload site@foo.service, /usr/bin/systemctl restart site@foo.service" "$HR/etc/sudoers.d/site-deploy"
check "bar's build_service grant"    grep -q "start --no-block site-build@bar.service" "$HR/etc/sudoers.d/site-deploy"
check "foo has no build grant"       bash -c '! grep -q "site-build@foo" "$HR/etc/sudoers.d/site-deploy"'
check "converge goes through root's tree" grep -qF "bin/site-tree.sh converge site *" "$HR/etc/sudoers.d/site-deploy"
check "no grant runs the engine directly" bash -c '! grep -q "bin/converge.sh" "$HR/etc/sudoers.d/site-deploy"'
check "no grant names the checkout"   bash -c '! grep -q "/srv/site/" "$HR/etc/sudoers.d/site-deploy"'

echo "16. a directory (not a symlink) already at /srv/foo is a name collision: refused, not clobbered"
rm -rf "$HR/srv/foo"; mkdir -p "$HR/srv/foo"; echo sentinel > "$HR/srv/foo/sentinel"
reset_log; run_ws
check "exit 1"                       [ "$(rc)" = 1 ]
check "named the collision"          grep -qi "name collision" "$T/out.txt"
check "did not touch the directory"  [ -f "$HR/srv/foo/sentinel" ]
rm -rf "$HR/srv/foo"; reset_log; run_ws   # heal it for the scenarios below
check "healed: exit 0"               [ "$(rc)" = 0 ]

echo "17. per-app monitoring is keyed on THAT app's own /etc/<app>/env, not the site's"
printf 'PROBE_URL=https://x/health\nHEALTHCHECKS_PROBE_URL=https://hc/x\n' > "$HR/etc/foo/env"
reset_log; run_ws
check "exit 0"                       [ "$(rc)" = 0 ]
check "foo's probe armed"            [ -e "$STUB_UNITS/site-probe@foo.timer.enabled" ]
check "bar's probe NOT armed"        [ ! -e "$STUB_UNITS/site-probe@bar.timer.enabled" ]
check "bar named as unprobed"        grep -q "bar: .*UNPROBED" "$T/out.txt"

echo "18. per-app packages: bar's own deploy/packages.txt is installed"
printf 'libbaronly1\n' > "$HR/srv/site/apps/bar/deploy/packages.txt"
reset_log; run_ws
check "exit 0"                       [ "$(rc)" = 0 ]
check "installed libbaronly1"        called "apt-get install"
check "named it"                     grep -q libbaronly1 "$T/out.txt"
printf '[deploy]\nreload = "reload"\nbuild_service = "site-build@bar.service"\nbackup_timeout = "2h"\n' > "$HR/srv/site/apps/bar/deploy/site.toml"
reset_log; run_ws
check "bar's backup_timeout: its own drop-in" grep -qx "TimeoutStartSec=2h" "$HR/etc/systemd/system/site-backup@bar.service.d/timeout.conf"
check "foo gets none"                [ ! -e "$HR/etc/systemd/system/site-backup@foo.service.d/timeout.conf" ]

echo "19. bar leaves the fleet: its symlink and armed timers are pruned"
printf '[hosts."the-host"]\napps = ["foo"]\n' > "$HR/srv/site/deploy/fleet.toml"

reset_log; run_ws
check "exit 0"                       [ "$(rc)" = 0 ]
check "bar's symlink removed"        [ ! -e "$HR/srv/bar" ]
check "said so"                      grep -q "bar: removed /srv/bar" "$T/out.txt"
check "bar's backup timeout drop-in removed" [ ! -e "$HR/etc/systemd/system/site-backup@bar.service.d" ]
check "foo's symlink untouched"      [ -L "$HR/srv/foo" ]

echo "19a. a site claiming ANOTHER app's name (or a system service's) gets no grant, drop-in or dir for it"
mkdir -p "$HR/srv/victim"                                   # another site's checkout on the same box
ln -s "$HR/srv/othersite/apps/victim2" "$HR/srv/victim2"     # another site's WORKSPACE app
printf '[hosts."the-host"]\napps = ["foo", "victim", "victim2", "sshd"]\n' > "$HR/srv/site/deploy/fleet.toml"
mkdir -p "$HR/srv/site/apps/victim/deploy" "$HR/srv/site/apps/sshd/deploy"
printf '[deploy]\nbuild_service = "site-build@victim.service"\n' > "$HR/srv/site/apps/victim/deploy/site.toml"
printf '[deploy]\nservice = "sshd.service"\n' > "$HR/srv/site/apps/sshd/deploy/site.toml"
reset_log; run_ws
check "exit 1"                           [ "$(rc)" = 1 ]
check "named the collision"              grep -q "victim: .*name collision" "$T/out.txt"
check "no grant over victim's units"     bash -c '! grep -q "victim" "$HR/etc/sudoers.d/site-deploy"'
check "no drop-in re-pointing victim's probe" [ ! -e "$HR/etc/systemd/system/site-probe@victim.service.d/site-deploy.conf" ]
check "nor victim2's (symlinked elsewhere)" [ ! -e "$HR/etc/systemd/system/site-probe@victim2.service.d/site-deploy.conf" ]
check "an app named sshd gets no sshd.service grant" bash -c '! grep -qE "(reload|restart) sshd(\.service)?(,|$)" "$HR/etc/sudoers.d/site-deploy"'
check "said REFUSED for it"              grep -q "sshd: REFUSED to grant reload/restart of sshd.service" "$T/out.txt"
check "foo still granted"                grep -q "reload site@foo.service" "$HR/etc/sudoers.d/site-deploy"
cp "$HR/srv/site/apps/foo/deploy/site.toml" "$T/foo-site.toml.bak"
printf '[deploy]\nreload = "reload"\nbuild_service = "site-backup@victim.service"\n' > "$HR/srv/site/apps/foo/deploy/site.toml"
reset_log; run_ws
check "a toolkit template instance is never granted, even when the site's name prefixes it" \
  bash -c '! grep -q "site-backup@victim" "$HR/etc/sudoers.d/site-deploy"'
cp "$T/foo-site.toml.bak" "$HR/srv/site/apps/foo/deploy/site.toml"
mkdir -p "$HR/srv/blog"                                      # another single-app site on the box
printf '[hosts."the-host"]\napps = ["foo", "blog-build", "site-extra"]\n' > "$HR/srv/site/deploy/fleet.toml"
mkdir -p "$HR/srv/site/apps/blog-build/deploy" "$HR/srv/site/apps/site-extra/deploy"
reset_log; run_ws
check "an app name extending another site's is refused" grep -q "REFUSED hosted app name blog-build: it extends /srv/blog" "$T/out.txt"
check "and never squats /srv"            [ ! -e "$HR/srv/blog-build" ]
check "extending this site's own name is fine" [ -L "$HR/srv/site-extra" ]
rm -rf "$HR/srv/blog" "$HR/srv/site-extra" "$HR/srv/site/apps/blog-build" "$HR/srv/site/apps/site-extra" "$HR/var/lib/site-extra"
# Siblings: shop and shop-api both ours -- stable on every tick, not just the first.
printf '[hosts."the-host"]\napps = ["foo", "shop", "shop-api"]\n' > "$HR/srv/site/deploy/fleet.toml"
mkdir -p "$HR/srv/site/apps/shop/deploy" "$HR/srv/site/apps/shop-api/deploy"
reset_log; run_ws; reset_log; run_ws
check "siblings shop/shop-api: tick 2 exit 0" [ "$(rc)" = 0 ]
check "shop-api still linked on tick 2"      [ -L "$HR/srv/shop-api" ]
# Reverse: another site's NEW /srv/shop cannot take our existing shop-api away.
rm "$HR/srv/shop"; mkdir -p "$HR/srv/shop"
printf '[hosts."the-host"]\napps = ["foo", "shop-api"]\n' > "$HR/srv/site/deploy/fleet.toml"
reset_log; run_ws
check "an existing app survives a new /srv prefix" [ -L "$HR/srv/shop-api" ]
check "and is not refused"                   bash -c '! grep -q "REFUSED hosted app name shop-api" "$T/out.txt"'
rm -rf "$HR/srv/shop" "$HR/srv/shop-api" "$HR/srv/site/apps/shop" "$HR/srv/site/apps/shop-api" "$HR/var/lib/shop" "$HR/var/lib/shop-api"
printf '[hosts."the-host"]\napps = ["foo"]\n' > "$HR/srv/site/deploy/fleet.toml"
rm -rf "$HR/srv/victim" "$HR/srv/victim2" "$HR/srv/sshd" "$HR/srv/site/apps/victim" "$HR/srv/site/apps/sshd" "$HR/var/lib/sshd"
printf '[hosts."the-host"]\napps = ["foo"]\n' > "$HR/srv/site/deploy/fleet.toml"
reset_log; run_ws

echo "19b. an apps_dir that climbs out of the site is refused"
cp "$HR/srv/site/deploy/site.toml" "$T/ws-site.toml.bak"
printf '[workspace]\napps_dir = "../../etc"\n' > "$HR/srv/site/deploy/site.toml"
reset_log; run_ws
check "exit 1"                       [ "$(rc)" = 1 ]
check "said REFUSED apps_dir"        grep -q "REFUSED \[workspace\] apps_dir" "$T/out.txt"
cp "$T/ws-site.toml.bak" "$HR/srv/site/deploy/site.toml"

echo "19c. a hosted app name that is not a plain name is refused, never used as a path"
printf '[hosts."the-host"]\napps = ["foo", "../../etc/evil"]\n' > "$HR/srv/site/deploy/fleet.toml"
reset_log; run_ws
check "exit 1"                       [ "$(rc)" = 1 ]
check "said REFUSED"                 grep -q "REFUSED hosted app name" "$T/out.txt"
check "no path escape"               bash -c '[ ! -e "$HR/etc/evil" ] && ! ls -d "$HR"/srv/*evil* >/dev/null 2>&1'
check "foo still converged"          [ -L "$HR/srv/foo" ]
printf '[hosts."the-host"]\napps = ["foo"]\n' > "$HR/srv/site/deploy/fleet.toml"

echo "20. probe_external (issue #24): the on-box probe is disarmed, not nagged UNPROBED"
printf '[deploy]\nreload = "reload"\nprobe_external = "foo.example-probe"\n' > "$HR/srv/site/apps/foo/deploy/site.toml"
reset_log; run_ws
check "exit 0"                       [ "$(rc)" = 0 ]
check "foo's on-box probe disarmed"  [ ! -e "$STUB_UNITS/site-probe@foo.timer.enabled" ]
check "said why"                     grep -q "probed externally (foo.example-probe)" "$T/out.txt"
check "foo NOT named unprobed"       bash -c '! grep -q "foo: .*UNPROBED" "$T/out.txt"'
check "the leftover pair is named"   grep -q "foo: .*are ignored" "$T/out.txt"
check "no sweep: UNVERIFIED nag"     grep -q "foo: .*UNVERIFIED" "$T/out.txt"
: > "$HR/etc/foo/env"
printf 'HEALTHCHECKS_API_KEY=k\nHEALTHCHECKS_SWEEP_TAG=fleet\n' > "$HR/etc/foo/ops-env"
reset_log; run_ws
check "with the sweep armed: no foo probe nag at all" bash -c '! grep -qE "foo: .*(UNPROBED|UNVERIFIED|ignored)" "$T/out.txt"'
check "foo's sweep armed"            [ -e "$STUB_UNITS/site-checks-armed@foo.timer.enabled" ]

echo "21. declarations are untrusted: an injected unit name never reaches sudoers (issue #31)"
cp "$HR/srv/app/deploy/site.toml" "$T/site.toml.bak" 2>/dev/null || : > "$T/site.toml.bak"
printf '[deploy]\nservice = "app.service, /bin/bash"\nbuild_service = "x.service,/usr/bin/env"\n' > "$HR/srv/app/deploy/site.toml"
reset_log; run
check "exit 1 (counted failure)"        [ "$(rc)" = 1 ]
check "said REFUSED"                    grep -q "REFUSED to grant reload/restart" "$T/out.txt"
check "build unit refused too"          grep -q "REFUSED to grant start of build unit" "$T/out.txt"
check "no shell in sudoers"             bash -c '! grep -qE "/bin/bash|/usr/bin/env" "$HR/etc/sudoers.d/app-deploy"'
check "refusal text not in sudoers"     bash -c '! grep -q REFUSED "$HR/etc/sudoers.d/app-deploy"'
check "the safe grants still written"   grep -q "host-converge.sh app" "$HR/etc/sudoers.d/app-deploy"
mkdir -p "$HR/srv/app-staging"                              # another site whose name extends this one's
for bad in reboot.target sshd sshd.service poweroff site-backup@victim.service site-backup@app.service cf-drift@app a:b other.service app-staging.service app-staging-build.service; do
  printf '[deploy]\nbuild_service = "%s"\n' "$bad" > "$HR/srv/app/deploy/site.toml"
  reset_log; run
  check "well-formed but not ours: $bad refused" bash -c '[ "$(cat "$T/rc.txt")" = 1 ] && ! grep -qF -- "'"$bad"'" "$HR/etc/sudoers.d/app-deploy"'
done
for good in app app.service app-build.service app@x.service site-build@app.service; do
  printf '[deploy]\nbuild_service = "%s"\n' "$good" > "$HR/srv/app/deploy/site.toml"
  reset_log; run
  check "ours: $good granted" grep -qF -- "start --no-block $good" "$HR/etc/sudoers.d/app-deploy"
done
rmdir "$HR/srv/app-staging"
cp "$T/site.toml.bak" "$HR/srv/app/deploy/site.toml"

echo "22. an option smuggled in as a package name never reaches apt-get"
printf 'libok1\n-oDPkg::Pre-Invoke::=touch /pwned\n--allow-unauthenticated\n' > "$HR/srv/app/deploy/packages.txt"
reset_log; run
check "exit 1"                          [ "$(rc)" = 1 ]
check "said REFUSED"                    grep -q "packages: REFUSED" "$T/out.txt"
check "apt never saw the option"        not_called "Pre-Invoke"
check "nor the flag"                    not_called "allow-unauthenticated"
check "the valid package still installed" called "libok1"
rm -f "$HR/srv/app/deploy/packages.txt"

echo "23. no grant names anything the service user can write (issue #31)"
check "no /srv/app/ path granted"       bash -c '! grep -q "/srv/app/" "$HR/etc/sudoers.d/app-deploy"'
check "no direct engine grant"          bash -c '! grep -q "bin/converge.sh" "$HR/etc/sudoers.d/app-deploy"'
check "no pin grant (root's own units pin)" bash -c '! grep -q "site-tree.sh pin" "$HR/etc/sudoers.d/app-deploy"'
check "converge through root's tree"    grep -qF "/srv/site-deploy/bin/site-tree.sh converge app *" "$HR/etc/sudoers.d/app-deploy"

echo "24. host-converge never pins the origin (the service user can run it); it says when a site that needs one has none"
mkdir -p "$HR/srv/app/.git"
printf '[remote "origin"]\n\turl = https://git.example/app.git\n' > "$HR/srv/app/.git/config"
printf '[deploy]\nconverge = true\n' > "$HR/srv/app/deploy/site.toml"
reset_log; run
check "never wrote a pin"               [ ! -e "$HR/etc/site-deploy/origin/app" ]
check "said WILL REFUSE"                grep -q "no pinned origin.*WILL REFUSE" "$T/out.txt"
mkdir -p "$HR/etc/site-deploy/origin"; printf 'url=git@github.com:o/app.git\n' > "$HR/etc/site-deploy/origin/app"
reset_log; run
check "ssh pin without key= is nagged"  grep -q "ssh URL with no key=" "$T/out.txt"
printf 'url=https://git.example/app.git\n' > "$HR/etc/site-deploy/origin/app"
reset_log; run
check "an https pin: no origin nag"     bash -c '! grep -q "WILL REFUSE" "$T/out.txt"'
rm -rf "$HR/srv/app/.git" "$HR/etc/site-deploy/origin"; : > "$HR/srv/app/deploy/site.toml"

echo "25. backup_timeout (issue #42): a per-app TimeoutStartSec drop-in for site-backup@, strictly validated"
dropin="$HR/etc/systemd/system/site-backup@app.service.d/timeout.conf"
reset_log; run
check "no knob: no drop-in"             [ ! -e "$dropin" ]
printf '[deploy]\nbackup_timeout = "2h"\n' > "$HR/srv/app/deploy/site.toml"
reset_log; run
check "exit 0"                          [ "$(rc)" = 0 ]
check "drop-in carries the timeout"     grep -qx "TimeoutStartSec=2h" "$dropin"
check "daemon-reloaded"                 called "daemon-reload"
reset_log; run
check "idempotent"                      not_called "daemon-reload"
printf '[deploy]\nbackup_timeout = "90min"\n' > "$HR/srv/app/deploy/site.toml"
reset_log; run
check "minutes are accepted"            grep -qx "TimeoutStartSec=90min" "$dropin"
for bad in 24h 1381min 0h 0min 90 1d 2h30min "2h\nExecStartPre=/bin/evil" "infinity" " 2h"; do
  printf '[deploy]\nbackup_timeout = "%s"\n' "$bad" > "$HR/srv/app/deploy/site.toml"
  reset_log; run
  check "refused $(printf %q "$bad"): exit 1"   [ "$(rc)" = 1 ]
  check "refused $(printf %q "$bad"): said so"  grep -q "REFUSED backup_timeout" "$T/out.txt"
  check "refused $(printf %q "$bad"): last good value kept" grep -qx "TimeoutStartSec=90min" "$dropin"
done
check "never an injected directive"     bash -c '! grep -q ExecStartPre "$1"' _ "$dropin"
printf '[deploy]\nbackup_timeout = "23h"\n' > "$HR/srv/app/deploy/site.toml"
reset_log; run
check "23h (the cap) is accepted"       grep -qx "TimeoutStartSec=23h" "$dropin"
for broken in '[deploy]\nbackup_timeout = "2h"\nservice = "x\n' 'deploy = "x"\n'; do
  printf "$broken" > "$HR/srv/app/deploy/site.toml"
  reset_log; run
  check "unreadable site.toml: exit 1"  [ "$(rc)" = 1 ]
  check "unreadable site.toml: drop-in kept, not treated as no knob" grep -qx "TimeoutStartSec=23h" "$dropin"
done
: > "$HR/srv/app/deploy/site.toml"
reset_log; run
check "knob removed: drop-in removed"   [ ! -e "$HR/etc/systemd/system/site-backup@app.service.d" ]
check "and daemon-reloaded"             called "daemon-reload"

echo
if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; else echo "all checks passed"; fi
exit $((fails > 0))
