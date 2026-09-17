#!/usr/bin/env bash
# Scenario tests for bin/cf-converge-run.sh: the root wrapper that derives the
# domain and the box's public IP, then calls the (separately tested)
# cf-converge.py reconciler.
#
# HOST_ROOT= points every FILE path at a sandbox; `curl` is a stub on PATH;
# CFC= and PYTHON= redirect the reconciler call itself to a fake script that
# records its argv and can be told what to print/exit, so this file tests only
# the wrapper's own logic (domain/IP resolution, argv shape, drift ping),
# never the real reconciler (see test-cf-converge.sh for that).
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); [ -s "$T/out.txt" ] && sed 's/^/         | /' "$T/out.txt" | tail -8; }
check() { local desc=$1; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }

T=$(mktemp -d); export T
if [ -n "${KEEP_SANDBOX:-}" ]; then trap 'echo "sandbox kept at $T"' EXIT; else trap 'rm -rf "$T"' EXIT; fi
export STUB_LOG="$T/calls.log"
HR="$T/root"; export HR
mkdir -p "$T/bin" "$HR/etc/app" "$HR/etc/site-deploy" "$HR/srv/app/deploy"
ln -s "$ROOT" "$HR/srv/site-deploy"

cat > "$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$STUB_LOG"
case "$*" in
  *169.254.169.254*) [ -n "${STUB_NO_METADATA:-}" ] && exit 1; printf '%s' "${STUB_METADATA_IP:-}" ;;
  *cdn-cgi/trace*)    [ -n "${STUB_NO_TRACE:-}" ] && exit 1; printf 'h=x\nip=%s\nts=1\n' "${STUB_TRACE_IP:-}" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$T/bin"/*
export PATH="$T/bin:$PATH"

cat > "$T/fake-cfc.sh" <<'STUB'
#!/usr/bin/env bash
echo "cfc $*" >> "$STUB_LOG"
[ -n "${STUB_CFC_OUT:-}" ] && printf '%s\n' "$STUB_CFC_OUT"
exit "${STUB_CFC_RC:-0}"
STUB
chmod +x "$T/fake-cfc.sh"

printf '{}' > "$HR/srv/app/deploy/cloudflare.json"

reset_log() { : > "$STUB_LOG"; }
called() { grep -qF -e "$1" "$STUB_LOG"; }
not_called() { ! grep -qF -e "$1" "$STUB_LOG"; }
run() {
  local extra=$1; shift
  env HOST_ROOT="$HR" CFC="$T/fake-cfc.sh" PYTHON=bash "$@" \
    bash "$ROOT/bin/cf-converge-run.sh" app $extra > "$T/out.txt" 2>&1
  echo $? > "$T/rc.txt"
}
rc() { cat "$T/rc.txt"; }

echo "1. no cloudflare.json: no-op, exit 0, reconciler never called"
mv "$HR/srv/app/deploy/cloudflare.json" "$T/cf.json.bak"
reset_log; run ""
check "exit 0"                 [ "$(rc)" = 0 ]
check "said nothing to converge" grep -qi "nothing to converge" "$T/out.txt"
check "cfc never called"        not_called "cfc "
mv "$T/cf.json.bak" "$HR/srv/app/deploy/cloudflare.json"

echo "2. cloudflare.json present but no domain anywhere: refuses"
reset_log; run ""
check "exit 1"                 [ "$(rc)" = 1 ]
check "said so"                grep -qi "refusing" "$T/out.txt"
check "cfc never called"       not_called "cfc "

echo "3. domain from deploy/site.toml's cf_domain knob"
cat > "$HR/srv/app/deploy/site.toml" <<'EOF'
[deploy]
cf_domain = "site.example"
EOF
reset_log; run ""
check "exit 0"                 [ "$(rc)" = 0 ]
check "domain passed through"  called -- "--domain site.example"

echo "4. an override in /etc/app/cf-env wins over site.toml"
echo "CF_DOMAIN=override.example" > "$HR/etc/app/cf-env"
reset_log; run ""
check "override used"          called -- "--domain override.example"
rm -f "$HR/etc/app/cf-env"

echo "5. public IP: host.env override wins over any curl call"
printf 'PUBLIC_IP=9.9.9.9\n' > "$HR/etc/site-deploy/host.env"
reset_log; run ""
check "override IP passed"     called -- "--public-ip 9.9.9.9"
check "no curl at all"         not_called "curl"
rm -f "$HR/etc/site-deploy/host.env"

echo "6. public IP: DO metadata used when no override"
reset_log; STUB_METADATA_IP=1.2.3.4 run ""
check "metadata IP passed"     called -- "--public-ip 1.2.3.4"

echo "7. public IP: cloudflare trace fallback when metadata is unavailable"
reset_log; STUB_NO_METADATA=1 STUB_TRACE_IP=5.6.7.8 run ""
check "trace IP passed"        called -- "--public-ip 5.6.7.8"

echo "8. public IP: both sources fail -> empty, warned, still proceeds"
reset_log; STUB_NO_METADATA=1 STUB_NO_TRACE=1 run ""
check "exit 0 (still ran)"     [ "$(rc)" = 0 ]
check "warned"                 grep -qi "could not derive public ip" "$T/out.txt"
check "empty --public-ip passed" called -- "--public-ip "

echo "9. default mode applies"
reset_log; run ""
check "apply passed"           called -- "--apply"
check "not verbose"            not_called "--verbose"

echo "10. --dry-run passes --verbose, never --apply"
reset_log; run "--dry-run"
check "verbose passed"         called -- "--verbose"
check "not apply"              not_called "--apply"

echo "11. --dry-run, no drift, a healthchecks URL set: pings clean (root), not /fail"
reset_log; HEALTHCHECKS_CF_DRIFT_URL=https://hc.example/d1 run "--dry-run"
check "pinged root"            called "https://hc.example/d1"
check "not /fail"              not_called "/d1/fail"

echo "12. --dry-run, drift reported (cfc printed a change): pings /fail"
reset_log; STUB_CFC_OUT="cf[a]: ssl mode strict -> full" HEALTHCHECKS_CF_DRIFT_URL=https://hc.example/d1 run "--dry-run"
check "exit 0 (dry-run itself did not fail)" [ "$(rc)" = 0 ]
check "pinged /fail"           called "https://hc.example/d1/fail"
check "body carries the diff"  called "ssl mode strict -> full"

echo "13. --dry-run, reconciler failed (rc=2): pings /fail too"
reset_log; STUB_CFC_RC=2 HEALTHCHECKS_CF_DRIFT_URL=https://hc.example/d1 run "--dry-run"
check "exit 2 propagated"      [ "$(rc)" = 2 ]
check "pinged /fail"           called "https://hc.example/d1/fail"

echo "14. apply mode never pings the drift check, even if the URL is set"
reset_log; HEALTHCHECKS_CF_DRIFT_URL=https://hc.example/d1 run ""
check "no curl to hc.example"  not_called "hc.example"

echo "15. the reconciler's exit code propagates"
reset_log; STUB_CFC_RC=2 run ""
check "exit 2"                 [ "$(rc)" = 2 ]

rm -f "$HR/srv/app/deploy/site.toml"

echo
if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; else echo "all checks passed"; fi
exit $((fails > 0))
