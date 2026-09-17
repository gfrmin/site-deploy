# shellcheck shell=bash
# lib/workspace.sh — Phase D item 14: which apps a site hosts, and where.
#
# Source it; do not execute it:   . /srv/site-deploy/lib/workspace.sh
#
# Three read-only, side-effect-free functions (no mkdir, no writes — safe to
# call from the unprivileged poller or from root-context converge scripts):
#
#   ws_apps <srv> <site>      hosted app names, one per line, on stdout
#   ws_apps_dir <srv>         the directory workspace members live under
#                              (deploy/site.toml [workspace] apps_dir, default "apps")
#   ws_site_of <root> <name>  the site that owns app/site <name>, derived from
#                              whether /srv/<name> is a symlink into a site's
#                              <apps_dir>/ (host-converge.sh creates that
#                              symlink); <name> itself if it is not

# ws_apps's precedence: an /etc/<site>/apps override file wins over
# deploy/fleet.toml, exactly like /etc/<app>/deploy-ref wins over site.toml's
# deploy_ref — a box-local file for the emergency case, deliberately NEVER
# converged, so a later tick cannot silently undo it while it is in effect.
# Its presence is nagged every tick, same as an unset monitoring knob.
#
# Read WHOLE and whitespace-split, never line-by-line: renavon's
# `read -r -a APPS < file` stopped at the first newline and silently never
# deployed an app appended on its own line (bechirot sat unreloaded that
# way). fleet-config.py's one-name-per-line output goes through the same
# split, so both sources share one "empty list" outcome below.
#
# Absent from both override and fleet.toml, or present but hosting nothing:
# said on stderr every tick, never silently — an ambiguous or empty app list
# must never look like a question this function already answered.
ws_apps() {   # <srv> <site>
  local srv=$1 site=$2
  local override="${WS_APPS_FILE:-/etc/$site/apps}"
  local self_dir rc
  self_dir=$(dirname "${BASH_SOURCE[0]}")
  local out_str=""
  if [ -r "$override" ]; then
    echo "workspace[$site]: apps overridden by $override (not converged — remove it to return to deploy/fleet.toml)" >&2
    out_str=$(cat "$override")
  elif [ -f "$srv/deploy/fleet.toml" ]; then
    out_str=$(python3 "${WS_FLEET_CONFIG:-$self_dir/../bin/fleet-config.py}" \
                "$srv/deploy/fleet.toml" "${BOX_HOSTNAME:-$(hostname)}")
    rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "workspace[$site]: deploy/fleet.toml is malformed; hosting NOTHING rather than guessing" >&2
      return 1
    fi
  else
    echo "workspace[$site]: no $override and no deploy/fleet.toml — hosting nothing" >&2
  fi
  # shellcheck disable=SC2206 # deliberate whitespace split, see above
  local -a names=($out_str)
  if [ "${#names[@]}" -eq 0 ]; then
    echo "workspace[$site]: hosts nothing (empty app list)" >&2
    return 0
  fi
  printf '%s\n' "${names[@]}"
}

# Read-only, never eval: this runs from root-context callers (host-converge.sh,
# converge.sh) too, so the value comes back through sed on the rendered
# `export WORKSPACE_APPS_DIR=...` line rather than `eval`ing anything a
# site.toml can influence — the same caution host-converge.sh already applies
# to DEPLOY_BUILD_SERVICE.
ws_apps_dir() {   # <srv>
  local srv=$1 self_dir dir
  self_dir=$(dirname "${BASH_SOURCE[0]}")
  dir=$(python3 "${WS_SITE_CONFIG:-$self_dir/../bin/site-config.py}" "$srv/deploy/site.toml" 2>/dev/null \
          | sed -n "s/^export WORKSPACE_APPS_DIR=//p" | tail -1 | tr -d "'\"")
  printf '%s\n' "${dir:-apps}"
}

# A workspace app has no /srv/<app> checkout of its own — host-converge.sh
# derives /srv/<app> as a symlink into /srv/<site>/<apps_dir>/<app>/. Reading
# that symlink back is how a caller that only has an app name (a `unit`
# instantiating a template, say) finds which site's queue directory and
# checkout it actually belongs to. Anything else — no symlink, or a symlink
# elsewhere — means <name> is its own site (today's single-app shape, or a
# name host-converge has not derived yet).
ws_site_of() {   # <root> <name>
  local root=$1 name=$2 target site
  target=$(readlink "$root/srv/$name" 2>/dev/null) || true
  case "$target" in
    "$root/srv/"*/*)
      # .../srv/<site>/<apps_dir>/<name>: the site is the path segment right
      # after srv/, whatever <apps_dir> is spelled and however deep the app
      # directory sits under it.
      site=${target#"$root"/srv/}
      printf '%s\n' "${site%%/*}"
      return 0
      ;;
  esac
  printf '%s\n' "$name"
}
