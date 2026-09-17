#!/usr/bin/env bash
# Self-contained check of the committed reference units systemd/app@.service
# and systemd/site-build@.service. No network, no root, no systemd: this
# reads the repo only.
#
# Ported from renavon-monorepo's test-systemd-units.sh (dataguru@.service /
# dataguru-build@.service) — the generic half. Each invariant here already
# broke a build or a reload silently once; none of it is visible to any
# Python test, since no app boots a TestClient and these units are never
# exercised anywhere else. Dropped: the fleet-wide gunicorn-floor scan across
# every app's pyproject.toml and the build-calendar overlap checks — both
# assume a monorepo with several apps' manifests in reach, which a per-app
# checkout consuming this toolkit does not have.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
cd "$ROOT" || exit 1
UNIT=systemd/app@.service
BUILD=systemd/site-build@.service

fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); }

echo "systemd units"

[ -r "$UNIT" ] || { fail "$UNIT missing"; exit 1; }
[ -r "$BUILD" ] || { fail "$BUILD missing"; exit 1; }

# systemd requires the continuation backslash to be the LAST character on the
# line: a single trailing space silently ENDS the directive there, with no
# error, and the unit still starts. Verified: with a space after
# `--keep-alive 5 \`, the parsed argv stops dead and --no-control-socket and
# --access-logfile both vanish.
if grep -qE '\\[[:blank:]]+$' "$UNIT"; then
  fail "app@: a continuation backslash is followed by trailing whitespace — systemd ends the directive there"
else
  pass "app@: no trailing whitespace after a continuation backslash"
fi

# Reconstruct the ExecStart LOGICAL line: drop comments, then join the
# backslash continuations. Everything below matches against THAT, never the
# raw file — the unit's own comments name the very flags under test, so a
# plain `grep -- --no-control-socket` would pass on a unit whose ExecStart
# lost the flag entirely.
execstart=$(
  sed '/^[[:space:]]*#/d' "$UNIT" \
    | awk '/^ExecStart=/ {c=1} c {printf "%s ", $0; if ($0 !~ /\\$/) exit} ' \
    | tr -d '\\'
)
[ -n "$execstart" ] || { fail "app@: no ExecStart= found"; exit 1; }

# A dangling backslash on the LAST ExecStart line makes systemd absorb the
# following directive into gunicorn's argv, which then exits 2 on
# "unrecognized arguments" — and Restart=always turns that into a crash loop.
case "${execstart#ExecStart=}" in
  *Exec*=*|*Restart=*)
    fail "app@: ExecStart swallowed a following directive — dangling continuation backslash?" ;;
  *)
    pass "app@: ExecStart does not swallow a following directive" ;;
esac

case "$execstart" in
  *--no-control-socket*)
    pass "app@: control socket disabled" ;;
  *)
    fail "app@: ExecStart lacks --no-control-socket — nothing invokes gunicornc, so the socket is pure cost, and dropping it widens the post-SIGHUP window old workers still accept connections on" ;;
esac

case "$execstart" in
  *' --workers '[0-9]*)
    pass "app@: --workers is a measured number, not left as a gunicorn default" ;;
  *)
    fail "app@: ExecStart has no --workers N — a small droplet OOMs on gunicorn's default worker count" ;;
esac

if grep -qE '^ExecReload=.*-HUP \$MAINPID' "$UNIT"; then
  pass "app@: ExecReload SIGHUPs the master"
else
  fail "app@: ExecReload does not SIGHUP \$MAINPID — reload would not rotate workers, and site-build@.service's post-build reload relies on this"
fi

# --- site-build@: the ExecStopPost chain -------------------------------------

if grep -qE '^ExecStopPost=-?\+.*systemctl reload' "$BUILD"; then
  pass "site-build@: post-build reload runs privileged (+ prefix)"
else
  fail "site-build@: post-build reload lacks the '+' prefix — sudo cannot work under NoNewPrivileges=yes, so it would fail silently"
fi

if grep -qE '^ExecStopPost=-?\+.*SERVICE_RESULT.*success' "$BUILD"; then
  pass "site-build@: post-build actions gated on SERVICE_RESULT"
else
  fail "site-build@: ExecStopPost is not gated on SERVICE_RESULT — a failed build would reload anyway"
fi

mapfile -t stop_post < <(grep -E '^ExecStopPost=' "$BUILD")
if [ "${#stop_post[@]}" -lt 2 ]; then
  fail "site-build@: expected at least two ExecStopPost= lines (reload, then purge); found ${#stop_post[@]}"
else
  # The purge must be LAST: it runs after the reload (or the edge refills from
  # the OLD build), and being last is what lets its gate exit non-zero — there
  # is nothing left to skip, so a non-zero status puts the unit in `failed`.
  case "${stop_post[-1]}" in
    *cf-purge.sh*) pass "site-build@: cf-purge.sh is the LAST ExecStopPost" ;;
    *)             fail "site-build@: the last ExecStopPost is not cf-purge.sh — the purge must follow the reload" ;;
  esac

  non_final_unguarded=0
  for i in $(seq 0 $((${#stop_post[@]} - 2))); do
    case "${stop_post[$i]#ExecStopPost=}" in
      -*) ;;
      *)  non_final_unguarded=1 ;;
    esac
  done
  if [ "$non_final_unguarded" = 0 ]; then
    pass "site-build@: every ExecStopPost before the last is '-' prefixed, so one failing cannot skip the purge"
  else
    fail "site-build@: an ExecStopPost before the last lacks the '-' prefix — if it fails, systemd silently skips cf-purge.sh entirely"
  fi

  reload_line=""
  for l in "${stop_post[@]}"; do
    case $l in ExecStopPost=-*+*"systemctl reload"*|ExecStopPost=+*"systemctl reload"*)
      [ -n "$reload_line" ] || reload_line=$l ;;
    esac
  done
  purge_line=${stop_post[-1]}
  marker=$(printf '%s' "$reload_line" | grep -oE '/var/lib/%i/\.[A-Za-z0-9._-]+' | head -n1)
  if [ -z "$marker" ]; then
    fail "site-build@: the reload ExecStopPost writes no /var/lib/%i/. marker — nothing can tell the purge step the reload failed"
  else
    ok=1
    case "$reload_line" in *": > $marker"*) ;; *) ok=0 ;; esac
    case "$reload_line" in *"rm -f $marker"*) ;; *) ok=0 ;; esac
    if [ "$ok" = 1 ]; then
      pass "site-build@: the reload step clears the marker, then writes it if the reload fails"
    else
      fail "site-build@: the reload step does not both clear ($marker) and write it on failure"
    fi

    before_purge=${purge_line%%cf-purge.sh*}
    if [ "$before_purge" = "$purge_line" ]; then
      fail "site-build@: could not split the purge ExecStopPost at cf-purge.sh"
    elif [[ $before_purge != *"$marker"* ]]; then
      fail "site-build@: cf-purge.sh is not gated on $marker — a failed reload would still purge, refilling the edge from the OLD build"
    elif [[ $before_purge != *"exit 1"* ]]; then
      fail "site-build@: the marker gate does not exit non-zero — the unit would report success after a broken post-build reload"
    else
      pass "site-build@: cf-purge.sh is gated on the reload marker, and the gate fails the unit"
    fi
  fi

  # --- the /fail ping ---------------------------------------------------
  ping_idx=-1; reload_idx=-1
  for i in "${!stop_post[@]}"; do
    case ${stop_post[$i]} in
      *HEALTHCHECKS_BUILD_URL*) [ "$ping_idx" -ge 0 ] || ping_idx=$i ;;
    esac
    if [ "${stop_post[$i]}" = "$reload_line" ] && [ "$reload_idx" -lt 0 ]; then
      reload_idx=$i
    fi
  done

  if [ "$ping_idx" -lt 0 ]; then
    fail "site-build@: no ExecStopPost pings healthchecks — an OOM-killed build (OOMScoreAdjust=500 makes that the designed failure mode) reports nowhere but the journal"
  else
    ping_line=${stop_post[$ping_idx]}

    if [ "$ping_idx" -gt "$reload_idx" ]; then
      pass "site-build@: the /fail ping runs after the reload, so it can see the marker"
    else
      fail "site-build@: the /fail ping runs BEFORE the reload — the marker does not exist yet, so a broken post-build reload would stay green"
    fi
    if [ "$ping_idx" -lt $((${#stop_post[@]} - 1)) ]; then
      pass "site-build@: the /fail ping is not the last ExecStopPost, so the purge keeps its exit 1"
    else
      fail "site-build@: the /fail ping is LAST — cf-purge.sh must be last so its exit 1 can fail the unit"
    fi

    ping_prefix=${ping_line#ExecStopPost=}; ping_prefix=${ping_prefix%%/*}
    case $ping_prefix in
      *-*) pass "site-build@: the /fail ping is '-' prefixed" ;;
      *)   fail "site-build@: the /fail ping lacks '-' — a healthchecks outage would skip cf-purge.sh entirely" ;;
    esac
    case $ping_prefix in
      *+*) fail "site-build@: the /fail ping is '+' prefixed — it would run as root outside the sandbox for no reason" ;;
      *)   pass "site-build@: the /fail ping runs unprivileged, inside the sandbox" ;;
    esac

    ok=1
    case $ping_line in *SERVICE_RESULT*) ;; *) ok=0 ;; esac
    case $ping_line in *"$marker"*)      ;; *) ok=0 ;; esac
    if [ "$ok" = 1 ]; then
      pass "site-build@: the /fail ping is gated on SERVICE_RESULT AND on $marker"
    else
      fail "site-build@: the /fail ping must consult BOTH SERVICE_RESULT and $marker — with only the first, a failed post-build reload leaves healthchecks GREEN"
    fi

    case $ping_line in
      *"rm "*"$marker"*|*"> $marker"*)
        fail "site-build@: the /fail ping writes or deletes $marker — the purge gate reads it AFTER this step and would stop firing" ;;
      *)
        pass "site-build@: the /fail ping only reads the marker" ;;
    esac

    case $ping_line in
      *'[ -n "$$HEALTHCHECKS_BUILD_URL" ]'*|*'[ -n "$HEALTHCHECKS_BUILD_URL" ]'*)
        pass "site-build@: the /fail ping no-ops when HEALTHCHECKS_BUILD_URL is unset" ;;
      *)
        fail "site-build@: the /fail ping has no [ -n ... ] gate on HEALTHCHECKS_BUILD_URL — an app without one would curl an empty URL on every failed build" ;;
    esac

    case $ping_line in
      *--max-time*) pass "site-build@: the /fail ping carries --max-time" ;;
      *)            fail "site-build@: the /fail ping has no --max-time — a blackholed connection blocks the stop-post chain until TimeoutStopSec kills it, taking cf-purge.sh with it" ;;
    esac
    case $ping_line in
      *--retry*)
        case $ping_line in
          *--retry-max-time*) pass "site-build@: the /fail ping's retry window is capped" ;;
          *)                  fail "site-build@: --retry without --retry-max-time — --max-time is PER ATTEMPT, so the step's real ceiling is not what it looks like" ;;
        esac ;;
    esac

    case $ping_line in
      *" -fsS"*|*" -f "*|*" --fail"*) pass "site-build@: the /fail ping treats a non-2xx as an error worth logging" ;;
      *) fail "site-build@: the /fail ping does not use curl -f — a 404 from a wrong healthchecks UUID would look like a delivered alarm" ;;
    esac

    # `%` is a systemd SPECIFIER. A known one is substituted; an UNKNOWN one
    # makes systemd log a warning and DROP THE ENTIRE ExecStopPost directive —
    # the later steps still run and the unit reports success, so the alarm
    # simply ceases to exist with nothing red anywhere. Strip $${...} shell
    # expansions first: a `%` inside one is a shell parameter operator, not a
    # specifier, and systemd tolerates it.
    spec_probe=$(printf '%s' "$ping_line" | sed 's/[$][$]{[^}]*}//g')
    spec_probe=${spec_probe//%%/}
    spec_probe=${spec_probe//%i/}
    case $spec_probe in
      *%*) fail "site-build@: the /fail ping contains a % that is neither %i nor %% — systemd silently drops the whole directive on an unknown specifier" ;;
      *)   pass "site-build@: the /fail ping uses no % specifier beyond %i/%%" ;;
    esac

    # `${...}` (single $) is resolved by SYSTEMD, not the shell, and a shell
    # parameter expansion is not a valid variable name to it — it evaluates to
    # the EMPTY STRING, silently, disarming the ping on every app forever.
    # `$${...}` reaches the shell intact.
    case ${ping_line//\$\$\{/} in
      *'${'*) fail "site-build@: the /fail ping uses a single-\$ \${...} — systemd resolves braced references itself and a shell expansion evaluates to the EMPTY STRING, silently disarming the ping. Write \$\${...}" ;;
      *)      pass "site-build@: the /fail ping's braced expansions are \$\$-escaped, so the shell resolves them" ;;
    esac
  fi
fi

echo
if [ "$fails" -eq 0 ]; then echo "all checks passed"; else echo "$fails check(s) failed"; fi
exit $((fails > 0))
