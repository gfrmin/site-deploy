#!/usr/bin/env bash
# converge.sh <app> — make the box a function of the app's OWN deploy/ tree,
# driven by a [converge] table in deploy/site.toml instead of a hand-written
# app-level script. Root. Idempotent, silent when unchanged.
#
# Opt-in and swappable: bin/auto-deploy.sh runs the app's own
# deploy/converge.sh when one exists; this is the toolkit's engine for an
# app that would rather DECLARE files than script them. Ported from
# webbsite's own converge.sh, which had already re-derived install/validate/
# reload/rollback for one app by hand, and from renavon-monorepo's
# dataguru-converge.sh (the state-tracked prune, the cold-start-race
# reasoning below).
#
# [converge] schema, in deploy/site.toml:
#
#   [[converge.files]]
#   src      = "deploy/app.service"          # relative to the app's repo
#   dst      = "/etc/systemd/system/app.service"
#   validate = "caddy"                       # optional: caddy | systemd-analyze | visudo
#   unit     = "app"                         # required iff apply is reload/restart
#   apply    = "reload"                      # optional: reload | restart | daemon-reload
#
#   [converge]
#   ensure_active = ["caddy"]   # started (once enabled) if found down, every tick
#   enable_timers = true        # every *.timer among the files above is enabled+started
#   prune         = true        # a dst this app installed before but no longer declares is deleted
#
# COLD-START RACE. If ensure_active just STARTED a unit this tick, that
# process already read whatever file converge just installed — reloading it
# immediately after is not merely redundant, it can lose a race with the
# daemon still coming up and report a failure that would roll back a file
# that was never actually wrong. So a reload target sharing a unit with one
# ensure_active just started is skipped, once, this tick only.
#
# ROLLBACK. A file whose apply is "reload" is backed up to "$dst.bak" before
# being overwritten; if the reload then fails, the backup is restored and
# reloaded again, and the run is marked failed regardless. A "restart" file
# gets no such treatment — restarting is already a hard cutover, and an app
# declaring restart has already accepted the downtime a bad file costs.
set -uo pipefail

APP=${1:?usage: converge.sh <app>}
ROOT="${HOST_ROOT:-}"
SELF="$ROOT/srv/site-deploy"
SRV="$ROOT/srv/$APP"
TOML="$SRV/deploy/site.toml"
STATE_DIR="${CONVERGE_STATE_DIR:-$ROOT/var/lib/$APP}"
MANIFEST="$STATE_DIR/converge-installed-files"

say() { echo "converge[$APP]: $*"; }
rc=0
note_failure() { rc=1; say "$*"; }

[ -f "$TOML" ] || { say "no deploy/site.toml; nothing declared"; exit 0; }

cfg=$(python3 "$SELF/bin/converge-config.py" "$TOML") \
  || { say "deploy/site.toml [converge] is malformed; refusing"; exit 1; }
[ -n "$cfg" ] || { say "no [converge] table declared; nothing to do"; exit 0; }

files_src=(); files_dst=(); files_validate=(); files_unit=(); files_apply=()
active_units=()
enable_timers=""
prune=""
# 0x1F (ASCII Unit Separator), not a tab: bash's `read` COLLAPSES consecutive
# IFS-whitespace delimiters (tab is one), which would shift every field after
# the first empty validate/unit left. See converge-config.py's docstring.
while IFS=$'\x1f' read -r kind a b c d e; do
  case "$kind" in
    FILE) files_src+=("$a"); files_dst+=("$b"); files_validate+=("$c"); files_unit+=("$d"); files_apply+=("$e") ;;
    ACTIVE) active_units+=("$a") ;;
    ENABLE_TIMERS) enable_timers=1 ;;
    PRUNE) prune=1 ;;
  esac
done <<< "$cfg"

validate_file() {   # <type> <path> <unit>
  local type=$1 path=$2 unit=$3
  case "$type" in
    "") return 0 ;;
    caddy)
      local user
      user=$(${SYSCTL_QUERY:-systemctl} show -p User --value "$unit" 2>/dev/null)
      if [ -n "$user" ]; then
        runuser -u "$user" -- caddy validate --adapter caddyfile --config "$path" >/dev/null 2>&1
      else
        caddy validate --adapter caddyfile --config "$path" >/dev/null 2>&1
      fi
      ;;
    systemd-analyze) systemd-analyze verify "$path" >/dev/null 2>&1 ;;
    visudo) visudo -cf "$path" >/dev/null 2>&1 ;;
  esac
}

daemon_reload_needed=""
reload_targets=()   # "<unit>:<dst>", one per changed reload-apply file
restart_units=()
cold_started=()      # ensure_active units this tick had to START
installed_now=()

for i in "${!files_src[@]}"; do
  src="$SRV/${files_src[$i]}"; dst="$ROOT${files_dst[$i]}"
  type="${files_validate[$i]}"; unit="${files_unit[$i]}"; apply="${files_apply[$i]}"
  installed_now+=("$dst")
  if [ ! -f "$src" ]; then
    note_failure "missing in repo, skipped: ${files_src[$i]}"
    continue
  fi
  if [ -f "$dst" ] && cmp -s "$src" "$dst"; then continue; fi
  if ! validate_file "$type" "$src" "$unit"; then
    note_failure "refusing to install $dst: failed $type validation"
    continue
  fi
  install -d -m0755 "$(dirname "$dst")"
  [ "$apply" = reload ] && [ -f "$dst" ] && cp -a "$dst" "$dst.bak"
  install -m0644 "$src" "$dst" || { note_failure "could not install $dst"; continue; }
  say "installed ${files_src[$i]} -> $dst"
  case "$apply" in
    daemon-reload) daemon_reload_needed=1 ;;
    reload) reload_targets+=("$unit:$dst") ;;
    restart) restart_units+=("$unit") ;;
  esac
done

if [ -n "$daemon_reload_needed" ]; then
  ${SYSCTL_QUERY:-systemctl} daemon-reload && say "daemon-reloaded" || note_failure "daemon-reload failed"
fi

# ensure_active: enabled if not, started if down. A unit an operator MASKED
# is a deliberate downtime and is left alone, same as host-converge.sh's
# stopped-WORK-timer rule.
for u in "${active_units[@]}"; do
  [ "$(${SYSCTL_QUERY:-systemctl} is-enabled "$u" 2>/dev/null)" = masked ] && continue
  ${SYSCTL_QUERY:-systemctl} is-enabled --quiet "$u" 2>/dev/null \
    || { ${SYSCTL_QUERY:-systemctl} enable --quiet "$u" || note_failure "could not enable $u"; }
  if ! ${SYSCTL_QUERY:-systemctl} is-active --quiet "$u" 2>/dev/null; then
    say "$u is down -- starting it"
    ${SYSCTL_QUERY:-systemctl} start "$u" && cold_started+=("$u") || note_failure "could not start $u"
  fi
done

declare -A reload_seen=()
for entry in "${reload_targets[@]}"; do
  unit=${entry%%:*}; dst=${entry#*:}
  [ -n "${reload_seen[$unit]:-}" ] && continue
  reload_seen[$unit]=1
  is_cold=""
  for c in "${cold_started[@]}"; do [ "$c" = "$unit" ] && is_cold=1; done
  if [ -n "$is_cold" ]; then
    say "$unit started fresh with the new file; no reload needed"
    rm -f "$dst.bak"
    continue
  fi
  if ${SYSCTL_QUERY:-systemctl} reload "$unit"; then
    say "$unit reloaded"
    rm -f "$dst.bak"
  else
    note_failure "$unit reload FAILED; restoring previous $dst"
    if [ -f "$dst.bak" ]; then
      cp -a "$dst.bak" "$dst" && ${SYSCTL_QUERY:-systemctl} reload "$unit"
    fi
  fi
done

for unit in "${restart_units[@]}"; do
  ${SYSCTL_QUERY:-systemctl} restart "$unit" && say "$unit restarted" || note_failure "$unit restart failed"
done

if [ -n "$enable_timers" ]; then
  for dst in "${files_dst[@]}"; do
    case "$dst" in *.timer) ;; *) continue ;; esac
    t=$(basename "$dst")
    [ "$(${SYSCTL_QUERY:-systemctl} is-enabled "$t" 2>/dev/null)" = masked ] && continue
    if ! ${SYSCTL_QUERY:-systemctl} is-enabled --quiet "$t" 2>/dev/null \
       || ! ${SYSCTL_QUERY:-systemctl} is-active --quiet "$t" 2>/dev/null; then
      ${SYSCTL_QUERY:-systemctl} enable --now --quiet "$t" && say "enabled $t" || note_failure "could not enable $t"
    fi
  done
fi

# prune: a dst this app installed on some EARLIER run but no longer declares
# is removed. State-tracked (not a directory scan), so a file the app never
# asked converge to manage is never at risk just because it happens to sit
# near one that is.
if [ -n "$prune" ]; then
  install -d -m0755 "$STATE_DIR"
  if [ -f "$MANIFEST" ]; then
    while IFS= read -r old; do
      [ -n "$old" ] || continue
      keep=""
      for d in "${installed_now[@]}"; do [ "$d" = "$old" ] && keep=1 && break; done
      [ -n "$keep" ] || { rm -f "$old" && say "pruned $old (no longer declared)"; }
    done < "$MANIFEST"
  fi
  printf '%s\n' "${installed_now[@]}" > "$MANIFEST"
fi

[ "$rc" = 0 ] || say "CONVERGE FAILED"
exit $rc
