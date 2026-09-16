#!/usr/bin/env bash
# hc-unit-result.sh <kind> — ExecStopPost= backstop for a unit whose SCRIPT owns
# the success edge of a healthchecks check.
#
#   ExecStopPost=-/srv/site-deploy/bin/hc-unit-result.sh deploy
#
# Pings HEALTHCHECKS_<KIND>_URL/fail when the unit did not end in success.
# /fail ONLY, never success: a success ping here would fire on every tick
# whatever the box's actual state, which is precisely the ran-dead-man the
# script's own reporter exists to avoid — green through a fetch that has
# failed every two minutes for a week. Also the only reporter that runs when
# the script never got to its own EXIT trap: a TimeoutStartSec kill, an OOM.
#
# A script rather than an inline `sh -c` in the unit, because systemd resolves
# `${VAR%/}` itself (to an empty string, silently) and treats `%` as a
# specifier; the unit-file spelling that survives both is unreadable and has
# been got wrong before.
set -u
kind=${1:?usage: hc-unit-result.sh <kind>}
var="HEALTHCHECKS_$(printf '%s' "$kind" | tr '[:lower:]' '[:upper:]')_URL"
url=${!var:-}
[ -n "$url" ] || exit 0
[ "${SERVICE_RESULT:-}" = success ] && exit 0
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib/hc.sh"
hc_ping "$url" /fail "site-deploy[$kind]: unit result ${SERVICE_RESULT:-unknown} (exit ${EXIT_CODE:-?}/${EXIT_STATUS:-?})"
exit 0
