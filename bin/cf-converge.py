#!/usr/bin/env python3
"""Converge one zone's Cloudflare config to what the app's repo declares.

The toolkit's host README claims a box is "a pure function of the repo + a
few secrets". host-converge.sh made that true of the box's *system* config;
this makes it true of the *edge* config too. Without this, a zone's SSL
mode, its apex/www DNS records and its cache rules are applied by hand from
committed JSON -- so a change in git reaches Cloudflare only if a human
remembers to curl it, which is how a cache rule can go missing on a zone
while it looks, from the origin, perfectly cacheable.

Desired state lives in the app's deploy/cloudflare.json. This reads it and
reconciles five things, each idempotently, each isolated from the others,
and each printing ONLY when it changes something:

  * ssl_mode         -- the zone's SSL/TLS encryption mode (/settings/ssl)
  * dns.a_records    -- the apex and www A records -> the serving box's public IP
  * cache_rules      -- the http_request_cache_settings phase entrypoint
  * waf_custom_rules -- the http_request_firewall_custom phase entrypoint
  * rate_limit_rules -- the http_ratelimit phase entrypoint

The three rule sections are reconciled identically: the declared list IS the
phase entrypoint (see "Shared zones" below for the one exception). Absent
means "this repo does not manage that phase" and the phase is not even
read; [] means "this phase must hold no rules".

Placeholders:
  * A rule's committed text may carry __PUBLIC_IP__, substituted here from
    --public-ip. It exists because a protection rule has to exempt the box
    itself: bin/cf-purge-verify.sh fetches the public URL back THROUGH
    Cloudflare on every build, as an ordinary curl GET carrying nothing that
    distinguishes it from a scraper, so a challenge on HTML GETs would print
    "cf-purge: WARNING unverified" forever -- the exact cry-wolf failure that
    file's own header comment exists to prevent.
  * Substitution happens BEFORE comparison, or a converged zone would report
    a diff on every tick and PUT the same rules forever.
  * An unresolved placeholder ABORTS the phase rather than shipping. An empty
    --public-ip is deliberately not substituted, so it aborts too: shipping
    `ip.src ne ` is a syntax error Cloudflare would reject (loud, fine), but
    an unknown __NAME__ can be ACCEPTED as an exemption that never matches --
    a silent hole in a rule whose whole job is not to have one.

Shared zones -- rule_scope:
  Two apps can share one Cloudflare zone (subdomains of one apex). A plain
  rule-phase declaration is whole-phase ownership, which would make the
  second app's converge delete the first app's rules on its very next tick.
  An app opts in with a top-level key in cloudflare.json:

      "rule_scope": {"host": "a.example", "shared_with": ["b.example"]}

  With it set, a phase owns exactly the declared rules whose `expression`
  names `host` (via `http.host eq/==/in {...}`) -- and ANY declared rule
  that does not name it is refused and reported, never silently applied
  under the wrong scope. Reading the live phase, every rule that names some
  OTHER host (not `host`, not in `shared_with`) is a foreign rule: it is
  left in the PUT body, in its original relative position, verbatim. Only
  the previously-owned rules are replaced, as a block, at the position of
  the first one found (or appended, if there were none yet). A rule naming
  both this scope's host and a host outside `shared_with` is ambiguous --
  refused and reported by name, same as one naming no scoped host at all.
  `shared_with` is the "unless listed explicitly" escape hatch for a rule
  the two apps have deliberately agreed to co-own.
  Without `rule_scope`, behaviour is unchanged: the declared list wholly
  replaces the phase, as it always has for a zone one app owns outright.

Safety:
  * DEFAULT IS DRY-RUN. Nothing is written without --apply, so the reconciler
    can be run against live to confirm the committed state matches reality
    before it is ever given a write path.
  * DNS is MANAGED-RECORDS, not declarative-sync: it touches only the A records
    it is told to (apex, www) and never deletes anything it did not declare, so
    MX/TXT/other records -- email, verification -- are never at risk.
  * More than one A record for a managed name is left untouched with a warning
    rather than guessed at.
  * PHASES ARE ISOLATED. One bad WAF expression must not be able to stop DNS or
    cache convergence in the same run: each phase is attempted, its failure
    reported, and the rest still run. The exit status still reflects it.
  * The single-zone scoped token (CF_CONFIG_TOKEN) grants DNS + cache-settings +
    zone-settings + WAF edit and nothing else -- notably not cache-purge, which
    is a separate token (bin/cf-purge.sh). If it leaks, the blast radius is one
    zone's config.

Auth: CF_CONFIG_TOKEN in the environment (a Bearer token). The domain is
passed by the caller; the ZONE ID is NOT. A scoped token can already see its
own zone in a name-filtered list (GET /zones?name=<domain> returns exactly
the one zone it is bound to), so the zone id is resolved from the domain
here rather than being a fact anyone enters -- in env or in the repo. The
only per-app identity is the domain, which already lives in BASE_URL, plus
the token. --zone stays as an optional override for testing or an odd
multi-zone setup. The box public IP is passed as a flag; the caller derives
it from the box's own metadata rather than from a hand-set value.

Exit status: 0 on success (converged or would-converge), 2 on a usage error
or if any phase failed. The caller treats a failure as non-fatal -- a
converge problem must not strand an otherwise-fine deploy.
"""
from __future__ import annotations

import argparse
import collections
import functools
import json
import os
import re
import socket
import sys
import urllib.error
import urllib.request

# A hung CF API call must not stall a caller (e.g. a build's ExecStartPre); the
# reconciler is idempotent, so a timed-out run just retries on the next deploy.
socket.setdefaulttimeout(20)

BASE = "https://api.cloudflare.com/client/v4"

# The fields that define a rule for comparison. Desired state is captured with
# exactly these keys, so a verbatim capture compares equal and the first
# converge is a no-op. One tuple serves all three rule phases because norm_rule
# copies a key only when the rule has it: `ratelimit` appears on http_ratelimit
# rules and nowhere else, so including it here cannot affect a cache rule.
RULE_KEYS = ("action", "action_parameters", "expression", "description",
             "enabled", "ratelimit")

# section in cloudflare.json -> Cloudflare ruleset phase. Order is the order
# they converge in.
RULE_PHASES = (
    ("cache_rules", "http_request_cache_settings"),
    ("waf_custom_rules", "http_request_firewall_custom"),
    ("rate_limit_rules", "http_ratelimit"),
)

# __NAME__ -- upper-case, so it cannot collide with a Cloudflare field
# (`http.request.uri.path`) or with anything a description would normally say.
PLACEHOLDER = re.compile(r"__[A-Z][A-Z0-9_]*__")

# host literals in an expression: `http.host eq "x"`, `== "x"`, or `in {"x" "y"}`.
# Scoped to http.host specifically (not a bare quoted-string heuristic) so a
# path segment or an unrelated description never reads as a host.
HOST_EQ = re.compile(r'http\.host\s*(?:eq|==)\s*"([^"]+)"')
HOST_IN = re.compile(r'http\.host\s+in\s*\{([^}]*)\}')

# "could not find entrypoint ruleset in the <phase> phase" -- a zone that has
# never had a rule in a phase has no ruleset at all, which is not an error.
NO_RULESET = 10003

RuleScope = collections.namedtuple("RuleScope", "host shared_with")
Ctx = collections.namedtuple("Ctx", "token zone domain public_ip apply rule_scope")


class CFError(Exception):
    def __init__(self, message, status=None, codes=()):
        super().__init__(message)
        self.status = status
        self.codes = tuple(codes)


def api(token, path, method="GET", body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        BASE + path, method=method, data=data,
        headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"},
    )
    status = None
    try:
        with urllib.request.urlopen(req) as r:
            payload = json.load(r)
    except urllib.error.HTTPError as e:
        status = e.code
        try:
            payload = json.load(e)
        except Exception:
            raise CFError(f"{method} {path}: HTTP {e.code}", status=status)
    if not payload.get("success"):
        errors = payload.get("errors") or []
        codes = [e.get("code") for e in errors if isinstance(e, dict)]
        raise CFError(f"{method} {path}: {errors}", status=status, codes=codes)
    return payload["result"]


def resolve_zone(token, domain):
    """Resolve a domain to its zone id using the token itself.

    A single-zone scoped token returns exactly its own zone from a name-filtered
    list, so this needs no account-wide Zone:Read -- the same token the caller
    already holds for writes answers "which zone is this?". Exactly one match is
    required: zero means the token cannot see the domain (wrong token, or the
    zone does not exist yet) and more than one is ambiguous -- both refuse
    rather than write to a guessed zone.
    """
    zones = api(token, f"/zones?name={domain}")
    if len(zones) != 1:
        raise CFError(
            f"resolve zone for {domain}: expected 1 zone, got {len(zones)} "
            "(is CF_CONFIG_TOKEN scoped to this domain's zone?)")
    return zones[0]["id"]


def norm_rule(rule):
    return {k: rule[k] for k in RULE_KEYS if k in rule}


def rule_hosts(rule):
    expr = rule.get("expression", "")
    hosts = set(m.group(1) for m in HOST_EQ.finditer(expr))
    for m in HOST_IN.finditer(expr):
        hosts |= set(re.findall(r'"([^"]+)"', m.group(1)))
    return hosts


def classify(rule, scope):
    """-> "owned" | "foreign" | "ambiguous", for a rule under a RuleScope.

    "foreign" also covers a rule that names no host at all: rule_scope claims
    only what explicitly names its host, so silence is never ownership.
    """
    hosts = rule_hosts(rule)
    if scope.host not in hosts:
        return "foreign"
    others = hosts - {scope.host} - set(scope.shared_with)
    return "ambiguous" if others else "owned"


def expand(rule, subs):
    """Substitute __NAME__ placeholders in a normalised rule; refuse unknowns.

    Substituting over the serialised rule rather than over `expression` alone
    means a placeholder works wherever it is written -- description, nested
    action_parameters -- and, more to the point, that the guard SEES it there
    too. A guard that only inspects `expression` is a guard with a blind spot,
    and the whole reason this function refuses is that a placeholder Cloudflare
    happens to accept is invisible afterwards.

    A substitution with an empty value is skipped, not applied: that leaves the
    placeholder in place and so takes the abort path, which is the right
    outcome for an underivable public IP (see the module docstring).
    """
    text = json.dumps(rule)
    for name, value in subs.items():
        if value:
            text = text.replace(f"__{name}__", value)
    unresolved = sorted(set(PLACEHOLDER.findall(text)))
    if unresolved:
        raise CFError(
            f"unresolved placeholder(s) {unresolved} in rule "
            f"{rule.get('description') or rule.get('expression', '')!r} -- "
            f"known: {sorted('__%s__' % k for k in subs)}. Refusing to ship: "
            "Cloudflare may ACCEPT a rule whose exemption never matches.")
    return json.loads(text)


def phase_rules(token, zone, phase):
    """The rules currently in a phase entrypoint; no ruleset at all reads as []."""
    try:
        entrypoint = api(token, f"/zones/{zone}/rulesets/phases/{phase}/entrypoint")
    except CFError as e:
        if e.status == 404 and NO_RULESET in e.codes:
            return []
        raise
    return entrypoint.get("rules", [])


def converge_ssl(cf, desired):
    want = desired.get("ssl_mode")
    if not want:
        return [], ["ssl_mode not declared; left untouched"]
    cur = api(cf.token, f"/zones/{cf.zone}/settings/ssl")["value"]
    if cur == want:
        return [], [f"ssl mode already {cur}"]
    if cf.apply:
        api(cf.token, f"/zones/{cf.zone}/settings/ssl", "PATCH", {"value": want})
    return [f"ssl mode {cur} -> {want}"], []


def converge_dns(cf, desired):
    """Managed records, not declarative sync: only the declared names are touched."""
    changes, oks = [], []
    for rec in desired.get("dns", {}).get("a_records", []):
        name = rec["name"]
        proxied = rec.get("proxied", True)
        fqdn = cf.domain if name == "@" else f"{name}.{cf.domain}"
        existing = api(cf.token, f"/zones/{cf.zone}/dns_records?type=A&name={fqdn}")
        if len(existing) > 1:
            print(f"cf[{cf.domain}]: WARNING {fqdn} has {len(existing)} A records; "
                  "leaving untouched", file=sys.stderr)
            continue
        if not existing:
            if not cf.public_ip:
                print(f"cf[{cf.domain}]: WARNING {fqdn} missing and no --public-ip; "
                      "skipping create", file=sys.stderr)
                continue
            changes.append(f"dns A {fqdn} -> {cf.public_ip} (proxied={proxied}) [create]")
            if cf.apply:
                api(cf.token, f"/zones/{cf.zone}/dns_records", "POST",
                    {"type": "A", "name": fqdn, "content": cf.public_ip,
                     "proxied": proxied, "ttl": 1})
            continue
        r = existing[0]
        # Reconcile content only when we know the box IP; always reconcile proxied.
        want_ip = cf.public_ip or r["content"]
        if r["content"] != want_ip or r["proxied"] != proxied:
            changes.append(f"dns A {fqdn}: {r['content']}(proxied={r['proxied']}) -> "
                           f"{want_ip}(proxied={proxied})")
            if cf.apply:
                api(cf.token, f"/zones/{cf.zone}/dns_records/{r['id']}", "PATCH",
                    {"type": "A", "name": fqdn, "content": want_ip,
                     "proxied": proxied, "ttl": 1})
        else:
            oks.append(f"dns A {fqdn} -> {r['content']} (proxied={r['proxied']})")
    return changes, oks


def converge_rules_scoped(cf, want, *, section, phase):
    """The rule_scope path of converge_rules: see the module docstring."""
    scope = cf.rule_scope
    owned_desired = []
    for r in want:
        cls = classify(r, scope)
        if cls == "owned":
            owned_desired.append(r)
            continue
        hosts = sorted(rule_hosts(r))
        if cls == "ambiguous":
            reason = (f"ambiguous -- names host(s) {hosts} outside rule_scope "
                      f"(host={scope.host!r}, shared_with={list(scope.shared_with)})")
        else:
            reason = f"does not name rule_scope host {scope.host!r} (hosts found: {hosts})"
        print(f"cf[{cf.domain}]: WARNING declared {section} rule refused -- {reason}",
              file=sys.stderr)
    # Expand (and so possibly abort) BEFORE the read, same reasoning as the
    # unscoped path: a rule we would refuse to ship should cost no API call.
    want_norm = [expand(norm_rule(r), {"PUBLIC_IP": cf.public_ip}) for r in owned_desired]

    cur_all = phase_rules(cf.token, cf.zone, phase)
    cur_norm_full = [norm_rule(r) for r in cur_all]

    result = []
    inserted = False
    for r in cur_all:
        if classify(r, scope) == "owned":
            if not inserted:
                result.extend(want_norm)
                inserted = True
            # else: a second (or later) previously-owned rule -- already
            # replaced by the block inserted at the first one's position.
        else:
            result.append(norm_rule(r))
    if not inserted:
        result.extend(want_norm)

    if result == cur_norm_full:
        return [], [f"{section} (scoped to {scope.host}) match ({len(want_norm)} owned rule(s))"]
    if cf.apply:
        api(cf.token, f"/zones/{cf.zone}/rulesets/phases/{phase}/entrypoint",
            "PUT", {"rules": result})
    foreign_kept = len(result) - len(want_norm)
    return [f"{section} (scoped to {scope.host}): {len(want_norm)} owned rule(s) applied, "
            f"{foreign_kept} foreign rule(s) kept"], []


def converge_rules(cf, desired, *, section, phase):
    want = desired.get(section)
    if want is None:
        return [], [f"{section} not declared; {phase} left untouched"]
    if cf.rule_scope is not None:
        return converge_rules_scoped(cf, want, section=section, phase=phase)
    # Expand (and so possibly abort) BEFORE the read: a rule we would refuse to
    # ship should cost no API call, and must never be compared in its raw form.
    want_norm = [expand(norm_rule(r), {"PUBLIC_IP": cf.public_ip}) for r in want]
    cur = [norm_rule(r) for r in phase_rules(cf.token, cf.zone, phase)]
    if cur == want_norm:
        return [], [f"{section} match ({len(cur)} rule(s))"]
    if cf.apply:
        api(cf.token, f"/zones/{cf.zone}/rulesets/phases/{phase}/entrypoint",
            "PUT", {"rules": want_norm})
    return [f"{section} {len(cur)} rule(s) -> {len(want_norm)} rule(s)"], []


PHASES = (
    ("ssl_mode", converge_ssl),
    ("dns", converge_dns),
) + tuple(
    (section, functools.partial(converge_rules, section=section, phase=phase))
    for section, phase in RULE_PHASES
)


def reconcile(cf, desired, verbose):
    """Run every phase, isolating failures. -> (changes, failed phase count).

    A phase that raises is reported and skipped; the others still converge.
    Sharing one try/except across every phase would mean a single bad WAF
    expression -- one committed character -- also stops the zone's DNS and
    cache from converging on every tick until someone notices.
    """
    tag = "" if cf.apply else "[dry-run] "
    changes = failed = 0
    for name, run in PHASES:
        try:
            acted, oks = run(cf, desired)
        except CFError as e:
            failed += 1
            print(f"cf[{cf.domain}]: {name} FAILED -- {e}", file=sys.stderr)
            continue
        changes += len(acted)
        for msg in acted:
            print(f"cf[{cf.domain}]: {tag}{msg}")
        if verbose:
            for msg in oks:
                print(f"cf[{cf.domain}]: ok -- {msg}")
    return changes, failed


def parse_rule_scope(desired):
    raw = desired.get("rule_scope")
    if raw is None:
        return None
    return RuleScope(host=raw["host"], shared_with=tuple(raw.get("shared_with", ())))


def main(argv=None):
    p = argparse.ArgumentParser(description="Converge a zone's Cloudflare config.")
    p.add_argument("--desired", required=True, help="path to cloudflare.json")
    p.add_argument("--domain", required=True, help="apex domain, e.g. example.com")
    p.add_argument("--zone", default="", help="Cloudflare zone id (default: resolve from --domain)")
    p.add_argument("--public-ip", default="", help="serving box public IP for A records and rule exemptions")
    p.add_argument("--apply", action="store_true", help="write changes (default: dry-run)")
    p.add_argument("--verbose", action="store_true", help="also print converged (no-op) checks")
    args = p.parse_args(argv)

    token = os.environ.get("CF_CONFIG_TOKEN", "")
    if not token:
        print("cf-converge: CF_CONFIG_TOKEN not set; skipping", file=sys.stderr)
        return 0
    try:
        with open(args.desired) as f:
            desired = json.load(f)
    except OSError as e:
        print(f"cf-converge: cannot read {args.desired}: {e}", file=sys.stderr)
        return 2
    try:
        zone = args.zone or resolve_zone(token, args.domain)
    except CFError as e:
        print(f"cf-converge[{args.domain}]: {e}", file=sys.stderr)
        return 2
    cf = Ctx(token=token, zone=zone, domain=args.domain,
             public_ip=args.public_ip, apply=args.apply,
             rule_scope=parse_rule_scope(desired))
    changes, failed = reconcile(cf, desired, args.verbose)
    if failed:
        # The count is what makes this line worth printing: it says how much of
        # the run DID land, which a single "converge failed" never could.
        print(f"cf-converge[{args.domain}]: {failed} phase(s) failed; "
              f"{changes} change(s) applied in the rest", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
