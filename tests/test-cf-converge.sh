#!/usr/bin/env bash
# Self-contained check of bin/cf-converge.py. No network, no credentials: the
# Cloudflare API is faked, so every call the reconciler would make is
# observable and nothing leaves the machine.
#
# Ported from renavon-monorepo's deploy/host/tests/test-cf-converge.sh
# (dataguru-cf-converge), which had no tests at all until a PROTECTION rule
# went in: the failure that matters for one of those is not "the rule was
# rejected" but "the rule was accepted and does not do what it says". Two of
# those are pinned here:
#
#   * an unresolved __PLACEHOLDER__ shipping literally. Cloudflare may accept
#     `ip.src ne __BOX_IP__` as a term that simply never matches -- an
#     exemption that silently is not one, with no error anywhere.
#   * a placeholder expanded AFTER comparison rather than before, which
#     reports a diff on a converged zone and re-PUTs the same rules forever.
#
# Added here: `rule_scope` (site-deploy's own addition, not in renavon) --
# two apps sharing one Cloudflare zone must each own only the rules that name
# their own host, never the other's, and never silently reorder them.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); }

echo "cf-converge: reconciler behaviour"
out=$(python3 - "$ROOT" <<'PY'
import contextlib, importlib.machinery, importlib.util, io, json, os, sys, tempfile

ROOT = sys.argv[1]
BIN = os.path.join(ROOT, "bin", "cf-converge.py")

loader = importlib.machinery.SourceFileLoader("cfc", BIN)
spec = importlib.util.spec_from_loader("cfc", loader)
cfc = importlib.util.module_from_spec(spec)
loader.exec_module(cfc)

ZONE = "z1"
IP = "134.199.238.232"
WAF = "http_request_firewall_custom"
CACHE = "http_request_cache_settings"
RL = "http_ratelimit"


def ep(phase):
    return f"/zones/{ZONE}/rulesets/phases/{phase}/entrypoint"


class Fake:
    """Stands in for cfc.api. Records every call; unknown ones are a failure.

    Deliberately strict: a phase that reads an entrypoint it was not supposed to
    touch raises here rather than quietly returning something plausible.
    """

    def __init__(self, responses=None, errors=None):
        self.responses = responses or {}
        self.errors = errors or {}
        self.calls = []

    def __call__(self, token, path, method="GET", body=None):
        self.calls.append((method, path, body))
        key = (method, path)
        if key in self.errors:
            raise self.errors[key]
        if key in self.responses:
            return self.responses[key]
        raise AssertionError(f"unexpected API call: {method} {path}")

    def bodies(self, method="PUT"):
        return [b for m, _, b in self.calls if m == method]

    def paths(self, method=None):
        return {p for m, p, _ in self.calls if method in (None, m)}


def run(desired, fake, apply=True, public_ip=IP, verbose=False, rule_scope=None):
    """reconcile() against the fake -> (changes, failed, stdout, stderr)."""
    cfc.api = fake
    o, e = io.StringIO(), io.StringIO()
    cf = cfc.Ctx(token="t", zone=ZONE, domain="site.example",
                 public_ip=public_ip, apply=apply, rule_scope=rule_scope)
    with contextlib.redirect_stdout(o), contextlib.redirect_stderr(e):
        changes, failed = cfc.reconcile(cf, desired, verbose)
    return changes, failed, o.getvalue(), e.getvalue()


results = []


def check(ok, msg):
    results.append(("OK " if ok else "BAD ") + msg)


CHALLENGE = {
    "action": "managed_challenge",
    "description": "box exempt",
    "enabled": True,
    "expression": '(http.request.method eq "GET" and ip.src ne __PUBLIC_IP__)',
}
LIVE_CHALLENGE = dict(CHALLENGE,
                      expression=f'(http.request.method eq "GET" and ip.src ne {IP})')
A_CACHE_RULE = {"action": "set_cache_settings", "expression": "true", "enabled": True}

SCENARIOS = []


def scenario(fn):
    SCENARIOS.append(fn)
    return fn


@scenario
def expansion_precedes_comparison():
    """A zone already holding the expanded rule is converged, not diffed forever."""
    f = Fake({("GET", ep(WAF)): {"rules": [LIVE_CHALLENGE]}})
    changes, failed, _, _ = run({"waf_custom_rules": [CHALLENGE]}, f)
    check(changes == 0 and failed == 0,
          f"a converged zone reports no change (got {changes} change(s), {failed} failure(s))")
    check(not f.bodies(), "and writes nothing")


@scenario
def expansion_precedes_the_put():
    """The body Cloudflare receives carries the IP, never the placeholder."""
    f = Fake({("GET", ep(WAF)): {"rules": []}, ("PUT", ep(WAF)): {}})
    run({"waf_custom_rules": [CHALLENGE]}, f)
    sent = json.dumps(f.bodies())
    check(IP in sent, "the PUT body carries the expanded IP")
    check("__PUBLIC_IP__" not in sent, "and no literal placeholder")


@scenario
def unknown_placeholder_aborts():
    """An unresolvable __NAME__ must never reach Cloudflare, which may accept it."""
    bad = dict(CHALLENGE, expression="ip.src ne __BOX_ADDRESS__")
    f = Fake()
    _, failed, _, err = run({"waf_custom_rules": [bad]}, f)
    check(failed == 1, f"an unknown placeholder fails the phase (failed={failed})")
    check(not f.calls, "and costs no API call at all")
    check("__BOX_ADDRESS__" in err, "and the error names the placeholder")


@scenario
def empty_public_ip_aborts():
    """An underivable IP takes the abort path rather than shipping `ip.src ne `."""
    f = Fake()
    _, failed, _, err = run({"waf_custom_rules": [CHALLENGE]}, f, public_ip="")
    check(failed == 1, "an underivable public IP aborts rather than shipping")
    check("__PUBLIC_IP__" in err, "and says which placeholder went unresolved")


@scenario
def absent_ruleset_reads_as_empty():
    """A zone that never had a rule in a phase has no ruleset: 404 + code 10003."""
    missing = cfc.CFError("no ruleset", status=404, codes=[10003])
    f = Fake({("PUT", ep(WAF)): {}}, {("GET", ep(WAF)): missing})
    changes, failed, _, _ = run({"waf_custom_rules": [CHALLENGE]}, f)
    check(failed == 0 and changes == 1, "a zone with no ruleset yet gets one created")


@scenario
def other_errors_are_not_an_empty_phase():
    """A 403 read as "no rules" would PUT desired state over a phase we cannot see."""
    denied = cfc.CFError("forbidden", status=403, codes=[10000])
    f = Fake(errors={("GET", ep(WAF)): denied})
    _, failed, _, _ = run({"waf_custom_rules": [CHALLENGE]}, f)
    check(failed == 1, "a 403 on the entrypoint is a failure, not an empty phase")
    check(not f.bodies(), "and nothing is written over a phase we could not read")


@scenario
def phases_are_isolated():
    """One committed character in a WAF expression must not stop DNS or cache."""
    f = Fake({("GET", ep(CACHE)): {"rules": []}, ("PUT", ep(CACHE)): {},
              ("GET", ep(RL)): {"rules": []}, ("PUT", ep(RL)): {}})
    changes, failed, _, _ = run({
        "cache_rules": [A_CACHE_RULE],
        "waf_custom_rules": [dict(CHALLENGE, expression="ip.src ne __NOPE__")],
        "rate_limit_rules": [{"action": "block", "expression": "true",
                              "enabled": True, "ratelimit": {"period": 10}}],
    }, f)
    check(failed == 1, "one broken phase fails alone")
    check(changes == 2, f"and the other two still converge (changes={changes})")
    check({ep(CACHE), ep(RL)} <= f.paths("PUT"), "cache and rate-limit were both written")


@scenario
def main_reports_the_partial_run():
    """Exit 2, and the summary says how much DID land -- the counter is not dead."""
    desired = {"cache_rules": [A_CACHE_RULE],
               "waf_custom_rules": [dict(CHALLENGE, expression="ip.src ne __NOPE__")]}
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
        json.dump(desired, fh)
        path = fh.name
    f = Fake({("GET", ep(CACHE)): {"rules": []}, ("PUT", ep(CACHE)): {}})
    cfc.api = f
    os.environ["CF_CONFIG_TOKEN"] = "t"
    o, e = io.StringIO(), io.StringIO()
    try:
        with contextlib.redirect_stdout(o), contextlib.redirect_stderr(e):
            rc = cfc.main(["--desired", path, "--domain", "site.example", "--zone", ZONE,
                           "--public-ip", IP, "--apply"])
    finally:
        os.unlink(path)
    check(rc == 2, f"main() exits 2 when a phase failed (rc={rc})")
    check("1 phase(s) failed" in e.getvalue() and "1 change(s)" in e.getvalue(),
          "and the summary carries both counts -- the change counter is no longer dead")


@scenario
def undeclared_phases_are_untouched():
    """Absent means "this repo does not manage that phase", not "empty it"."""
    f = Fake({("GET", ep(CACHE)): {"rules": []}, ("PUT", ep(CACHE)): {}})
    run({"cache_rules": [A_CACHE_RULE]}, f)
    check(ep(WAF) not in f.paths() and ep(RL) not in f.paths(),
          "an undeclared phase is never even read")


@scenario
def an_empty_declared_phase_is_a_no_op_when_empty():
    f = Fake({("GET", ep(RL)): {"rules": []}})
    changes, failed, _, _ = run({"rate_limit_rules": []}, f)
    check(changes == 0 and failed == 0 and not f.bodies(),
          "an empty declared phase that is already empty writes nothing")


@scenario
def a_verbatim_capture_is_a_no_op():
    """What makes "capture the live rule, then leave it alone" safe."""
    live = {
        "action": "block",
        "description": "Throttle non-verified clients hammering /company/*",
        "enabled": True,
        "expression": '(http.request.method eq "GET" and not cf.client.bot)',
        "ratelimit": {"characteristics": ["ip.src", "cf.colo.id"],
                      "mitigation_timeout": 10, "period": 10,
                      "requests_per_period": 5, "requests_to_origin": True},
    }
    served = dict(live, id="9d70", ref="9d70", version="1", last_updated="2026-05-11")
    f = Fake({("GET", ep(RL)): {"rules": [served]}})
    changes, failed, _, _ = run({"rate_limit_rules": [live]}, f)
    check(changes == 0 and failed == 0, "a verbatim rate-limit capture is a no-op")
    check(not f.bodies(), "so the rule keeps its id")


@scenario
def a_differing_ratelimit_block_is_seen():
    """The converse: `ratelimit` is compared, not ignored as an unknown key."""
    live = {"action": "block", "expression": "true", "enabled": True,
            "ratelimit": {"period": 10, "requests_per_period": 5}}
    f = Fake({("GET", ep(RL)): {"rules": [live]}, ("PUT", ep(RL)): {}})
    want = dict(live, ratelimit={"period": 10, "requests_per_period": 50})
    changes, _, _, _ = run({"rate_limit_rules": [want]}, f)
    check(changes == 1, "a changed rate-limit threshold is a change")


@scenario
def expand_is_identity_without_placeholders():
    plain = {"action": "block", "expression": 'http.host eq "site.example"', "enabled": True}
    check(cfc.expand(plain, {"PUBLIC_IP": IP}) == plain,
          "expand() is the identity on a rule with no placeholders")


# --- rule_scope: two apps sharing one zone -----------------------------------

SCOPE = cfc.RuleScope(host="a.example", shared_with=())
A_RULE = {"action": "block", "enabled": True,
          "expression": 'http.host eq "a.example" and http.request.uri.path eq "/x"'}
B_RULE = {"action": "block", "enabled": True,
          "expression": 'http.host eq "b.example" and http.request.uri.path eq "/y"'}
AMBIGUOUS_RULE = {"action": "block", "enabled": True,
                   "expression": '(http.host eq "a.example" or http.host eq "b.example")'}


@scenario
def scoped_owns_only_its_own_host():
    """A phase with rule_scope set claims only rules naming its host."""
    f = Fake({("GET", ep(WAF)): {"rules": [B_RULE]}, ("PUT", ep(WAF)): {}})
    changes, failed, _, _ = run({"waf_custom_rules": [A_RULE]}, f, rule_scope=SCOPE)
    check(failed == 0, "no failures")
    check(changes == 1, f"the owned rule is added (changes={changes})")
    put = f.bodies()[0]["rules"]
    check(B_RULE in put, "the foreign rule survives in the PUT body")
    check(any(r.get("expression") == A_RULE["expression"] for r in put),
          "the owned rule is in the PUT body too")


@scenario
def scoped_leaves_foreign_rules_in_relative_order():
    """Two foreign rules either side of the owned one keep their positions."""
    foreign1 = dict(B_RULE, description="b1")
    foreign2 = dict(B_RULE, description="b2", expression='http.host eq "b.example" and true')
    live_owned = dict(A_RULE, description="old-a")
    f = Fake({("GET", ep(WAF)): {"rules": [foreign1, live_owned, foreign2]},
              ("PUT", ep(WAF)): {}})
    changes, failed, _, _ = run({"waf_custom_rules": [A_RULE]}, f, rule_scope=SCOPE)
    check(failed == 0 and changes == 1, "the changed owned rule is the one change")
    put = f.bodies()[0]["rules"]
    descs = [r.get("description") for r in put]
    check(descs == ["b1", None, "b2"] or descs.index("b1") < descs.index("b2"),
          f"foreign rules keep their relative order (got {descs})")
    check(put[descs.index("b1") + 1 if "b1" in descs else 0].get("expression")
          == A_RULE["expression"], "the owned rule replaced its old self in place")


@scenario
def ambiguous_rule_is_skipped_and_reported_not_applied():
    """A declared rule naming a host outside the scope is refused, not shipped."""
    f = Fake({("GET", ep(WAF)): {"rules": []}})
    changes, failed, _, err = run({"waf_custom_rules": [AMBIGUOUS_RULE]}, f, rule_scope=SCOPE)
    check(failed == 0, "an ambiguous rule does not fail the phase")
    check(changes == 0, "and is not counted as applied")
    check(not f.bodies(), "nothing is PUT")
    check("b.example" in err and "ambiguous" in err.lower(),
          "the skip is reported by name")


@scenario
def shared_with_allows_an_explicitly_named_cross_host_rule():
    """The escape hatch: a rule naming both hosts, explicitly allowed."""
    scope = cfc.RuleScope(host="a.example", shared_with=("b.example",))
    f = Fake({("GET", ep(WAF)): {"rules": []}, ("PUT", ep(WAF)): {}})
    changes, failed, _, err = run({"waf_custom_rules": [AMBIGUOUS_RULE]}, f, rule_scope=scope)
    check(failed == 0 and changes == 1, f"explicitly shared rule is applied (changes={changes})")
    check("ambiguous" not in err.lower(), "and is not reported as ambiguous")


@scenario
def a_declared_rule_not_naming_the_scoped_host_is_refused():
    """Declaring B's rule under A's scope must not let A claim it."""
    f = Fake({("GET", ep(WAF)): {"rules": []}})
    changes, failed, _, err = run({"waf_custom_rules": [B_RULE]}, f, rule_scope=SCOPE)
    check(failed == 0 and changes == 0, "not applied")
    check(not f.bodies(), "nothing written")
    check("a.example" in err, "the report names the scope that refused it")


@scenario
def unscoped_desired_is_still_whole_phase_ownership():
    """No rule_scope at all: today's behaviour, byte for byte."""
    f = Fake({("GET", ep(WAF)): {"rules": [B_RULE]}, ("PUT", ep(WAF)): {}})
    changes, failed, _, _ = run({"waf_custom_rules": [A_RULE]}, f, rule_scope=None)
    check(failed == 0 and changes == 1, "unscoped: the declared list wholly replaces the phase")
    check(f.bodies()[0]["rules"] == [cfc.norm_rule(A_RULE)],
          "the foreign rule is NOT preserved when no rule_scope is set")


for fn in SCENARIOS:
    try:
        fn()
    except Exception as exc:  # noqa: BLE001 -- a crash is this scenario's failure, not the suite's
        check(False, f"{fn.__name__} raised {type(exc).__name__}: {exc}")

for line in results:
    print(line)
PY
)
while IFS= read -r line; do
  case "$line" in
    OK*) pass "${line#OK }" ;;
    *)   fail "${line#BAD }" ;;
  esac
done <<<"$out"

echo
if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; else echo "all checks passed"; fi
exit $((fails > 0))
