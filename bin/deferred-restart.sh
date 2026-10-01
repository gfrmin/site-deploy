#!/usr/bin/env bash
# deferred-restart.sh <site> — restart the units <site> deferred from
# needrestart, but only the ones still running on a replaced library (root).
#
# `[host] defer_restart` in the site's site.toml (issue #49) takes units such
# as postgresql@17-main out of needrestart's hands: unattended-upgrades would
# otherwise restart the database on every upgrade that touches a library it
# maps (libssl, libxml2, glib, ...), twice in nine days in the HK afternoon on
# webbsite. host-converge writes the prefixes to a root-owned list and arms
# site-deferred-restart@<site>.timer, weekly in the upgrade window; this is
# what it runs. A unit is stale when its main process maps a file under
# /usr/lib, /lib, /usr/bin, ... that has since been replaced — the kernel marks
# that mapping "(deleted)". Shared memory (/dev/zero, /SYSV*, /dev/shm) is
# deleted-by-design and never counts.
#
# One failed restart does not stop the others; the run then exits non-zero.
set -uo pipefail

SITE=${1:?usage: deferred-restart.sh <site>}
ROOT="${HOST_ROOT:-}"
LIST="$ROOT/etc/site-deploy/deferred-restart/$SITE"

say() { echo "deferred-restart[$SITE]: $*"; }
[ -r "$LIST" ] || { say "no $LIST — nothing is deferred"; exit 0; }
# The list is root-owned and host-converge validated it; re-checked against
# the toolkit's allow-list anyway, since it decides what root restarts.
ALLOWED="$(dirname "${BASH_SOURCE[0]}")/../host/deferrable-restart.txt"
mapfile -t prefixes < <(grep -xFf <(grep -vE '^\s*(#|$)' "$ALLOWED") "$LIST")
[ ${#prefixes[@]} -gt 0 ] || { say "$LIST names no units — nothing is deferred"; exit 0; }

deferred() { local p; for p in "${prefixes[@]}"; do case $1 in "$p"*) return 0 ;; esac; done; return 1; }
stale() {   # <pid>
  grep -qE '[[:space:]]/(usr/)?(s?bin|lib(32|64|x32)?|libexec)/[^[:space:]]* \(deleted\)$' "$ROOT/proc/$1/maps" 2>/dev/null
}

failed=0 seen=0
while read -r unit; do
  deferred "$unit" || continue
  seen=$((seen + 1))
  pid=$(systemctl show -p MainPID --value "$unit" 2>/dev/null)
  if [ -z "$pid" ] || [ "$pid" = 0 ]; then say "$unit: no main process; skipped"; continue; fi
  if ! stale "$pid"; then say "$unit: current (no replaced library mapped)"; continue; fi
  if systemctl restart "$unit"; then say "$unit: RESTARTED onto the upgraded libraries"
  else say "$unit: restart FAILED"; failed=$((failed + 1)); fi
done < <(systemctl list-units --type=service --state=running --plain --no-legend 2>/dev/null | awk '{ print $1 }')

[ "$seen" -gt 0 ] || say "no running unit matches ${prefixes[*]}"
[ "$failed" -eq 0 ] || { say "FAILED — $failed unit(s) did not restart"; exit 1; }
exit 0
