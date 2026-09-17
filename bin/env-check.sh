#!/usr/bin/env bash
# env-check.sh <app> — does this box carry the config the app declares, and is
# the RUNNING app on it?
#
#   env-check.sh <app>        reads /srv/<app>/deploy/required-env.txt against /etc/<app>/*
#   ETC=, MANIFEST=, UNIT=, PROC_ROOT=   overrides for fixtures and tests
#
# WHY THIS EXISTS. A site rendered no purchase CTA of any kind for four days
# after a droplet rebuild reconstructed its env file with 16 of the 31
# variables the app reads. Every signal stayed green: pages returned 200, the
# nightly build succeeded, the edge purge fired and verified. It stayed green
# because an unset knob hid that feature *by design* — correct for a fresh
# deploy, catastrophic for a rebuilt box. Nothing anywhere asserted that a
# running app HAS its config; only that it was running. On a fleet of cattle,
# "rebuilt from nothing" is the normal case, so this is the check that says a
# rebuilt box equals the one it replaced.
#
# THE MANIFEST (deploy/required-env.txt, in the app repo, names only):
#
#   # file       NAME       grade[@fresh]   what breaks without it
#   env          SECRET_KEY required        the app
#   refresh-env  R2_KEY     required        the loader
#
#   file      relative to /etc/<app>/ (env is the app unit's EnvironmentFile)
#   required  must be present AND non-blank
#   optional  may be absent; BLANK is reported (see below)
#   blank-ok  absent and blank are the same to the code; never reported
#   @fresh    the long-lived serving process never reads it — its consumers
#             re-read the file on every run (a Type=oneshot unit, cf-purge.sh)
#             — so it is excluded from the booted-config comparison
#
# Honest in BOTH directions: a name present on the box that the manifest does
# not declare is a failure, so a knob cannot exist only in /etc.
#
# PRESENCE, NEVER CONTENT. This reads the env files only to learn which NAMES
# carry a non-empty value, and prints names and reasons — never a value. It
# does not source them: that would put every secret into this process's
# environment and thence into every child it spawns.
#
# BLANK IS NOT ABSENT — not to every reader, which is why the manifest grades
# each name rather than this script assuming. Where the default lives in the
# `os.getenv(name, default)` call, os.getenv falls back only when the name is
# ABSENT, so `POOL_SIZE=` is `int("")`, a ValueError at import that crash-loops
# the unit, and `R2_ENDPOINT=` is `Invalid endpoint: https://` on every run.
# Both are strictly worse than leaving the line out.
#
# THE FILE IS NOT THE PROCESS. systemd reads EnvironmentFile= at unit START and
# a reload is SIGHUP (gunicorn forks fresh workers from an os.environ fixed at
# exec time). Nothing restarts an app because its env file changed, so a
# restored file would turn this check green at exactly the moment an operator
# is watching, while the app kept serving the config it booted with. So when
# the `env` file is newer than the unit start, /proc/<MainPID>/environ — the
# config the app actually booted with — is compared variable-by-variable
# (in-process, never printed), skipping @fresh names. When the environ cannot
# be read it falls back to a warning on the mtime alone, and says so.
#
# EXIT STATUS — callers must tell 1 from 2:
#   0  nothing to report
#   1  the config is wrong: a required name absent/blank, an optional name
#      blank, an undeclared name present, a declared file missing, or the
#      running app not on the file
#   2  the check itself could not run (unreadable file, malformed manifest).
#      A broken checker that exits 0 reads as a clean bill of health, which is
#      the precise failure this script exists to remove — BLIND is never clean.
set -uo pipefail

app=${1:?usage: env-check.sh <app>}
ETC="${ETC:-/etc/$app}"
MANIFEST="${MANIFEST:-/srv/$app/deploy/required-env.txt}"
UNIT="${UNIT:-$app.service}"
PROC_ROOT="${PROC_ROOT:-/proc}"
say() { echo "env-check: $app: $*"; }

[ -r "$MANIFEST" ] || { say "BLIND: cannot read $MANIFEST"; exit 2; }

# --- read the manifest --------------------------------------------------------
declare -A GRADE=() FRESH=() REASON=()
declare -a FILES=() ORDER=()
malformed=0; lineno=0
while IFS= read -r line || [ -n "$line" ]; do
  lineno=$((lineno + 1))
  trimmed=${line#"${line%%[![:space:]]*}"}
  case $trimmed in ""|\#*) continue;; esac
  read -r file name grade reason <<<"$trimmed"
  key="$file $name"
  if ! [[ $name =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    say "manifest $MANIFEST:$lineno: '$name' is not an env var name"; malformed=1; continue
  fi
  if [ -n "${GRADE[$key]:-}" ]; then
    say "manifest $MANIFEST:$lineno: $file $name listed twice"; malformed=1; continue
  fi
  case $grade in *@fresh) FRESH[$key]=1; grade=${grade%@fresh} ;; esac
  case $grade in
    required|optional|blank-ok) ;;
    *) say "manifest $MANIFEST:$lineno: $name has grade '${grade:-<none>}', expected required, optional or blank-ok (optionally @fresh)"
       malformed=1; continue ;;
  esac
  # A report that names a variable and stops does not tell an operator what
  # broke, so the reason is part of the format, not a nicety.
  if [ -z "${reason:-}" ]; then
    say "manifest $MANIFEST:$lineno: $name has no reason"; malformed=1; continue
  fi
  GRADE[$key]=$grade; REASON[$key]=$reason; ORDER+=("$key")
  case " ${FILES[*]-} " in *" $file "*) ;; *) FILES+=("$file") ;; esac
done < "$MANIFEST"
[ "$malformed" = 0 ] || exit 2

# --- one pass over each env file: which names have a value, which are blank ---
# Later assignments win, matching systemd's EnvironmentFile semantics — and a
# later BLANK assignment therefore overrides an earlier value.
declare -A HAS=() BLANK=() VAL=()
parse_env() {   # $1 = file, keys stored as "file NAME"
  local f=$1 line name val
  while IFS= read -r line || [ -n "$line" ]; do
    case ${line#"${line%%[![:space:]]*}"} in ""|\#*) continue;; esac
    [[ $line =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    name=${BASH_REMATCH[1]}; val=${BASH_REMATCH[2]}
    # Trim, unquote one layer, trim again: `VAR= "x" ` and `VAR="x"` both mean
    # x, and `VAR=""` means empty. [:space:] covers a stray CR.
    val=${val#"${val%%[![:space:]]*}"}; val=${val%"${val##*[![:space:]]}"}
    case $val in \"*\") val=${val#\"}; val=${val%\"} ;; \'*\') val=${val#\'}; val=${val%\'} ;; esac
    val=${val#"${val%%[![:space:]]*}"}; val=${val%"${val##*[![:space:]]}"}
    if [ -n "$val" ]; then HAS["$f $name"]=1; unset "BLANK[$f $name]"
    else BLANK["$f $name"]=1; unset "HAS[$f $name]"; fi
    VAL["$f $name"]=$val    # in-process only, for the booted-config comparison
  done < "$ETC/$f"
}

rc=0
for f in "${FILES[@]}"; do
  if [ ! -e "$ETC/$f" ]; then say "MISSING FILE $ETC/$f"; rc=1; continue; fi
  if [ ! -r "$ETC/$f" ]; then say "BLIND: cannot read $ETC/$f (run as root)"; exit 2; fi
  parse_env "$f"
done

# --- report per name -----------------------------------------------------------
for key in "${ORDER[@]}"; do
  f=${key%% *}; name=${key#* }
  [ -e "$ETC/$f" ] || continue
  case ${GRADE[$key]} in
    required)
      if [ -z "${HAS[$key]:-}" ]; then
        rc=1
        if [ -n "${BLANK[$key]:-}" ]; then
          say "$f: REQUIRED $name is set to an EMPTY VALUE, which is not the same as leaving it out — ${REASON[$key]}"
        else
          say "$f: REQUIRED $name is absent — ${REASON[$key]}"
        fi
      fi ;;
    optional)
      if [ -n "${BLANK[$key]:-}" ]; then
        rc=1
        say "$f: optional $name is SET TO AN EMPTY VALUE, which is not the same as leaving it out — the declared default applies only to an ABSENT name, so the app reads the empty string. Delete the line or give it a value — ${REASON[$key]}"
      elif [ -z "${HAS[$key]:-}" ]; then
        say "$f: optional $name absent (${REASON[$key]})"
      fi ;;
  esac
done
# The other direction: a knob that exists only in /etc.
for key in "${!HAS[@]}" "${!BLANK[@]}"; do
  [ -n "${GRADE[$key]:-}" ] && continue
  rc=1
  say "${key%% *}: ${key#* } is set on the box but NOT declared in $MANIFEST"
done

# --- is the running app still on the `env` file? -------------------------------
# Advisory and best-effort by construction: no systemd, a unit that has never
# run, or an unparseable timestamp all mean "cannot tell", and cannot-tell must
# stay silent rather than manufacture a warning. Only an ACTIVE unit is
# compared — an inactive one gets started later and reads the file then.
env_file="$ETC/env"
if [ -r "$env_file" ] && command -v systemctl >/dev/null 2>&1 \
   && systemctl is-active --quiet "$UNIT" 2>/dev/null; then
  started=$(systemctl show -p ExecMainStartTimestamp --value "$UNIT" 2>/dev/null)
  # The `-n` guard is load-bearing and NOT redundant with the parse below:
  # systemd reports an EMPTY timestamp for a unit that has never run, and
  # `date -d ""` does not fail on that — it resolves to TODAY AT MIDNIGHT.
  if [ -n "$started" ] \
     && started_epoch=$(date -d "$started" +%s 2>/dev/null) \
     && env_epoch=$(stat -c %Y "$env_file" 2>/dev/null) \
     && [ "$env_epoch" -gt "$started_epoch" ]; then
    main_pid=$(systemctl show -p MainPID --value "$UNIT" 2>/dev/null)
    environ_file="$PROC_ROOT/${main_pid:-0}/environ"
    if [[ ${main_pid:-} =~ ^[0-9]+$ ]] && [ "$main_pid" -gt 0 ] && [ -r "$environ_file" ]; then
      declare -A BOOT=()
      while IFS= read -r -d '' kv; do
        case $kv in =*|'') continue ;; *=*) BOOT[${kv%%=*}]=${kv#*=} ;; esac
      done < "$environ_file"
      drifted=()
      for key in "${ORDER[@]}"; do
        [ "${key%% *}" = env ] || continue
        [ -z "${FRESH[$key]:-}" ] || continue
        name=${key#* }
        # SET-NESS IS PART OF THE VALUE: absent and blank must not collapse, or
        # deleting a blank line reads as no divergence while the app keeps
        # serving the blank. The `+s` marker keeps file-absent ("") distinct
        # from booted-blank ("s"). EDGE WHITESPACE IS NOT: the booted value
        # gets the same trim the file parser applied, or one quoted padded
        # value becomes a permanent false drift no restart can clear.
        boot_val="${BOOT[$name]-}"
        boot_val=${boot_val#"${boot_val%%[![:space:]]*}"}; boot_val=${boot_val%"${boot_val##*[![:space:]]}"}
        [ "${VAL[$key]+s}${VAL[$key]-}" = "${BOOT[$name]+s}${boot_val}" ] || drifted+=("$name")
      done
      if [ ${#drifted[@]} -gt 0 ]; then
        rc=1
        say "the running app is NOT on this file: ${drifted[*]} differ(s) between $env_file and what $UNIT booted with (values compared in-process, never printed). systemd reads EnvironmentFile= only at unit start and a reload is SIGHUP, so the app is still serving the old value(s). apply: fix anything reported above FIRST, then \`systemctl restart $UNIT\`."
      fi
      # else silent, deliberately: every variable the serving process reads
      # matches what it booted with, so the edit touched only @fresh config.
    else
      rc=1
      say "$env_file was modified $(date -d "@$env_epoch" '+%Y-%m-%d %H:%M:%S %Z'), but $UNIT has been running since $started. systemd reads EnvironmentFile= only at unit start and a reload is SIGHUP, so the app is still serving the config it booted with. (Could not read the app's boot-time environment to compare variable-by-variable, so if the edit touched only @fresh variables this is a false alarm.) apply: \`systemctl restart $UNIT\`."
    fi
  fi
fi

[ "$rc" -eq 0 ] && say "ok (${#ORDER[@]} names across ${#FILES[@]} files)"
exit "$rc"
