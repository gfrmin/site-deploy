# site-deploy

Git **push-to-deploy** for a small fleet of sibling sites that share one shape: a `uv`-managed
Python app (FastAPI/Flask) run by gunicorn under systemd, checked out at `/srv/<app>` and pulling
`master`. One shared, parameterized toolkit instead of a copy of the deploy glue per repo.

## Why
A common self-hosted setup has no auto-deploy: pushing to `master` does nothing until someone SSHes
in and runs `git pull && uv sync && (tailwindcss) && systemctl reload` by hand — so boxes silently
drift behind `origin`. This closes that gap with **no CI, no webhook, and no inbound exposure**.

## How it works
Each box runs a tiny systemd **instance** timer that polls `origin/master` every ~2 min (as the
service user, over the box's existing read-only git deploy key) and self-deploys if it moved. The
instance name `%i` is the app, which is also the service user, `/srv/%i`, and `/etc/%i/env`, so a
single unit template covers every app with no per-app rendering.

```
git push ─▶ origin/master
                ▲ git fetch (every ~2 min, as the service user)
        site-deploy@<app>.timer ─▶ site-deploy@<app>.service ─▶ bin/auto-deploy.sh
              │ ff-only pull ▸ uv sync ▸ (css, canaried) ▸ reload ▸ HEALTH ▸ cf-purge
              ▼  live within ~2 min
```

`bin/auto-deploy.sh` is byte-identical on every box; per-app differences come from
**`deploy/site.toml` in the app's own repo** (see below), falling back to `DEPLOY_*` vars in
`/etc/<app>/env`. The CSS build is auto-detected by the presence of `static/src.css`.

**A deploy is not finished when the merge lands — it is finished when the new code is reloaded and
answering.** The reload is gated on a health probe, and the edge purge is gated on that probe
passing, because purging before the origin serves the new code just refills the edge from stale, or
from a 500. If anything between the merge and a healthy reload fails, a marker file makes the next
tick resume rather than see "up to date" and quietly turn the failed unit green.

**Snapshot-backed apps:** if a deploy changes `data/build_db.py` and `DEPLOY_BUILD_SERVICE` is set,
the poller reloads onto the new code **immediately** and *also* dispatches that build unit (rebuild
the snapshot, then re-reload + re-purge via its `--reload-service`). The reload can't be deferred:
Jinja reads templates from disk, so once the pull lands the old workers are already rendering the
new templates — old Python under new templates 500s on any template that needs new Python (live
incident, crescira 2026-07-12). The app-side contract that makes the early reload safe: new code
must degrade gracefully on the previous snapshot schema (feature-detect new tables/columns rather
than assuming them).

**Safety:** fast-forward only, with an ancestor check that bails loudly on a drifted or ahead box
(rather than reload-looping), and it **never reloads if `uv sync` or the CSS build fails** — the old
workers keep serving.

## Provisioning a new box

```
host/cloud-init.yaml    first boot: admin user + Tailscale, nothing else
host/provision.sh <app> packages, uv, service user (swap etc. are host-converge's, every tick)
host/harden.sh          key-only sshd + ufw (tailnet + Cloudflare ranges only)
```

**Confirm `ssh g@<box>` works over Tailscale SSH before running `harden.sh`.** It closes public
`:22`, and doing that first is a live lockout needing the provider's recovery console.

`harden.sh` raises ufw (deny incoming, tailnet allowed) and calls `bin/ufw-cloudflare-sync.sh` for
the initial 80/443 allow-list, then enables `ufw-cloudflare-sync.timer` so the list stays in step
daily — Cloudflare's ranges change occasionally, and a box that never re-fetches them silently
drifts either into rejecting a new range or trusting one Cloudflare has since given back. The sync
script only ever touches rules it tagged itself (`comment cf-sync`): never `ufw reset`, never the
tailnet rule, never anything an operator added by hand.

The host layer is promoted from dataguru's `deploy/host/`, which had absorbed the incident fixes.
What stayed behind is the part that is genuinely dataguru-shaped: a uv *workspace* of four apps
under one lock, and `/etc/dataguru/apps`.

## Layout
```
bin/auto-deploy.sh   generic poller (run by the timer, as the service user)
bin/self-update.sh   keeps /srv/site-deploy on the toolkit's tested ref (run by a root timer)
bin/cf-purge.sh      Cloudflare edge purge (no-op without CF_CACHE_PURGE_TOKEN); bin/cf-purge-verify.sh checks it actually evicted
bin/health-probe.sh  active public probe -> its healthchecks check (see Monitoring)
bin/hc-unit-result.sh ExecStopPost= backstop: /fail when a unit did not end in success
bin/env-check.sh     does the box carry every env NAME deploy/required-env.txt declares? (see below)
bin/checks-armed.sh  are the fleet's healthchecks alarms actually armed? (paused = silent)
lib/hc.sh            the ping leaf + http_probe, sourced by every reporter
bin/host-converge.sh converge the box below the app every tick: units, grants, journald, swap, packages, Caddy policy, timers (root)
bin/install.sh       bootstrap: root-own the toolkit, first host-converge, env-check (admin, once)
bin/site-config.py   deploy/site.toml -> DEPLOY_*/WORKSPACE_* env; --app-keys renders only the per-app subset
bin/fleet-config.py  deploy/fleet.toml -> which apps this hostname hosts (workspace mode; see below)
lib/workspace.sh     ws_apps/ws_apps_dir/ws_site_of: which apps a site hosts, and where (workspace mode)
bin/ufw-cloudflare-sync.sh diff-apply ufw's 80/443 allow-list to Cloudflare's current ranges (root)
bin/cf-converge.py   converge one zone's Cloudflare config (SSL/DNS/cache/WAF/rate-limit) to deploy/cloudflare.json
bin/cf-converge-run.sh root wrapper: derives the domain + the box's public IP, calls cf-converge.py
bin/backup.sh        encrypt deploy/backup-producer.sh's stdout, ship off-box, verify by round trip, prune (root)
bin/converge.sh       generic [converge]-table engine: install/validate/reload-with-rollback/prune (root)
bin/converge-config.py deploy/site.toml [converge] table -> bin/converge.sh's bash arrays
systemd/site-deploy@.service , site-deploy@.timer          per-app instance units
systemd/site-deploy-update.service , site-deploy-update.timer   per-box toolkit updater (root)
systemd/site-probe@.service , site-probe@.timer            per-app active probe (every 5 min)
systemd/site-checks-armed@.service , site-checks-armed@.timer   alarm-armed sweep (every 15 min)
systemd/ufw-cloudflare-sync.service , ufw-cloudflare-sync.timer   daily Cloudflare range sync (root)
systemd/cf-converge@.service   applies deploy/cloudflare.json, dispatched by the poller on change (root)
systemd/cf-drift@.service , cf-drift@.timer   daily dry-run drift report for cloudflare.json (root)
systemd/site-backup@.service , site-backup@.timer   daily off-box backup, dispatched iff deploy/backup-producer.sh exists (root)
systemd/app@.service   reference gunicorn unit for an app (copy, do not converge — see below)
systemd/site-build@.service   reference build unit: reload -> /fail -> purge, ordering pinned by tests
host/                provisioning: cloud-init, provision.sh, harden.sh, packages.txt, and the files host-converge installs
example.env          the per-app DEPLOY_* knobs to append to /etc/<app>/env
```

## The toolkit gates itself

A merge to this repo's `master` used to reach every box within two minutes: the poller pulled
the toolkit itself, as the service user, best-effort and silently. Now `.github/workflows/tests.yml`
advances `refs/heads/ci-green` only after the suite passes on `master`, and a root timer
(`site-deploy-update.timer` → `bin/self-update.sh`) fast-forwards `/srv/site-deploy` onto that
ref. A box can only ever run a toolkit commit whose whole suite was green.

**There is no fallback to `master` if the ref is missing.** A gate that opens when it cannot find
its own lock is not a gate. The updater refuses, loudly, every tick, and the box keeps the last
known-good toolkit. Escape hatch when CI itself is broken:

```
sudo systemctl edit site-deploy-update.service     # [Service] Environment=SITE_DEPLOY_REF=master
```

**Trust boundary, restated for the toolkit.** Root executes scripts out of `/srv/site-deploy`
(the app's `deploy/converge.sh` today, more later), so the toolkit is **root-owned** and the
service user cannot write it; `install.sh` does the one-time `chown` on boxes bootstrapped before
this. For the same reason the poller refuses to run `deploy/converge.sh` unless the app's `deploy/`
tree is byte-identical to the merged commit (no modified tracked files, nothing untracked): an RCE
in the app must not become root two minutes later by editing a script in place.

## Per-app config: `deploy/site.toml` in the app repo

The knobs that decide how a deploy behaves belong next to the code they deploy, where a pull request
can review them. They used to live only in `/etc/<app>/env` on the box — which nothing diffs, and
where nothing notices drift. That is how webbsite's committed systemd unit ended up missing an
`ExecReload` the box had been relying on for months.

```toml
[deploy]
reload       = "reload"            # or "restart" for a unit with no ExecReload
uv_args      = "--frozen --no-dev"
port         = 8000
health_path  = "/health"           # probed on 127.0.0.1:$port after the reload
health_match = '"ok"'              # a 200 from a half-booted worker is not health
cf_zone_id   = "..."               # non-secret half of the purge
cf_domain    = "example.com"       # apex domain for cf-converge.py (see below); non-secret
tailwindcss_version = "4.3.3"      # apps with static/src.css: pin the compiler (see below)
# deploy_ref = "ci-green"          # deploy the TESTED ref, not the tip of master (see below)
# service       = "<app>.service"         # the unit reloaded/restarted (default: <app>.service)
# build_service = "<app>-build.service"   # snapshot-backed apps only
# build_inputs  = ["data/build_db.py"]    # paths whose change dispatches build_service (default shown)
# converge      = true                    # apply deploy/ to the box each tick (see below)
```

`service` and `build_inputs` exist for workspace mode (Phase D item 14: several apps served from
one checkout) — `service` because a workspace app's unit is `<site>@<app>.service`, not
`<app>.service`; `build_inputs` because a snapshot-backed app's build reads more than one exact
file (a directory prefix fails *open* into one extra rebuild, which is the safe direction, where
an allow-list of exact files fails *closed* into a silently stale snapshot). A single-app site
never needs either — the defaults already match today's behaviour.

### `deploy_ref`: deploy the tested ref, not the tip of master

A push to `master` reaches the box within two minutes, so every safety property otherwise rests on
a human running the tests before merging. If the app's CI fast-forwards a `ci-green` ref only after
a green run on `master` (a ~15-line job; this repo's own `tests.yml` is the template), then
`deploy_ref = "ci-green"` makes the box fast-forward onto that ref instead. The clone keeps
`master` checked out; only what is compared and merged changes.

- **No fallback if the ref is missing.** A gate that opens when it cannot find its own lock is not
  a gate. The poller refuses, loudly, every tick, and the dead-man gets `/fail`.
- **A ref that stops moving is not "where the box should be."** While `master` is ahead, the
  poller logs how far behind the ref is; once the ref has not moved for an hour (`REF_FROZEN_SECONDS`),
  a level tick sends `/fail` instead of the root ping. A busy day of green merges never trips it.
- **Emergency override:** a ref name in `/etc/<app>/deploy-ref` wins over site.toml (write
  `master` when CI itself is broken). Deliberately a file, not a converged setting.
- The fetch uses an explicit `+refs/heads/*` refspec, so a `--single-branch` clone cannot starve
  the ref, and `--prune`, so a deleted ref cannot pass the existence check from a stale copy.
- The ref is read from site.toml *before* the fetch (it decides what to fetch), so a commit that
  changes `deploy_ref` governs the next deploy, not its own.

### The reload contract

`reload = "reload"` is `systemctl reload <app>`, i.e. the unit's `ExecReload=`. A unit with none
makes the verb a silent no-op: every deploy "succeeds" while the old workers keep serving, which is
how one box ran for months. And gunicorn's SIGHUP re-imports the app only when `preload_app` is
False. The poller checks both after converge and before the verb, and refuses with the fix named.
`reload = "restart"` needs neither.

### The health contract

`health_path` gates the reload → purge step. **With `health_match` set, the body is the datum and
the status code is ignored**: a snapshot-backed app's `/health` answers 503 on a stale snapshot
while serving every page, and a status-code probe would call it down, skip the purge, and strand
the deploy's templates at the edge for a full TTL. Without `health_match` the status code is all
there is, and a non-2xx is down. Keep this endpoint *shallow* (is the new code up?): a stale
feed must not wedge the deploy that carries the fix. Point the external probe (`health-probe.sh`)
at the *deep* variant if the app has one.

### Dependencies, stylesheets, and the things `uv` will do to you

- **A deploy that changes `uv.lock` restarts instead of reloading.** SIGHUP re-forks gunicorn's
  workers under the interpreter and gunicorn the arbiter was started with; only a restart execs
  the newly synced ones. `install.sh` grants both verbs for this reason. A resumed deploy remembers
  the verb in its marker.
- **A `uv.lock` re-locked in place on the box is discarded before the merge.** Every `uv run` here
  carries `--frozen --no-dev`, because an unflagged one rewrites the lock on a pyproject mismatch,
  after which every fast-forward fails forever as "drift". An operator pasting an unflagged
  `uv run` from a runbook gets the same recovery.
- **Every `@source "…"` in `static/src.css` must resolve on the box before the build runs.**
  `tailwindcss` exits 0 with a near-empty stylesheet when a source path is mistyped, and the size
  canary alone misses apps whose src.css is mostly hand-written CSS. `@source not` / `inline()`
  forms are reported rather than skipped, so two parsers of one syntax cannot drift silently.
- **Pin `tailwindcss_version`.** Unset, `pytailwindcss` fetches `releases/latest` when the venv is
  first created, so each box compiles with whatever upstream had published that day. The pin takes
  effect on a box's next fresh venv (the download is cached by version).

### The box below the app converges too

`converge = true` also runs `bin/host-converge.sh <app>` (root, out of the root-owned toolkit, never
the app checkout) right before the app's `deploy/converge.sh`. Silent when nothing changed; every
change is one line; a failed step is counted and the run ends with one greppable
`HOST-CONVERGE FAILED` line, which stops the deploy before the reload like any other failure. It
owns, every tick:

- the toolkit's own units in `/etc/systemd/system` (re-installed on change, daemon-reloaded; a
  changed timer is restarted only if an operator has not stopped it)
- the service user's scoped `NOPASSWD` grants (`reload` and `restart`, the build unit, the two
  converge scripts), validated with `visudo -cf` before they replace the live file
- a journald cap (`SystemMaxUse=1G`, a month of retention), unattended security upgrades, and a
  `needrestart` rule so an upgrade never restarts a running `<app>-*` batch unit mid-run (the
  app's own long-lived unit stays eligible on purpose)
- `host/packages.txt` plus the app's `deploy/packages.txt`, installed on diff only
- a 4G swapfile and `vm.swappiness=10` (moved here from `provision.sh`)
- wherever Caddy is installed, a drop-in with `Restart=always` and a memory ceiling, so an OOM
  kill of the proxy is local and recoverable instead of five days of 521s
  (`CADDY_MEMORY_HIGH`/`CADDY_MEMORY_MAX` in `/etc/site-deploy/host.env` for a different box size)
- the timers: the toolkit updater and the poller always; the probe and the alarm sweep iff their
  env names are set, disarmed when they are removed. A stopped alarm timer is re-armed: to stand
  a probe down, blank its env pair and pause the check. Missing monitoring is nagged every tick.

`install.sh` is now just the bootstrap: root-own the toolkit, run the first converge, run
`env-check`. "Installed" and "converged" are one state, which is what makes a rebuilt box
provably equal to the one it replaced.

### `converge = true` — keeping a box in step with its repo

`host/provision.sh` builds a box **once**. Nothing afterwards keeps its systemd units, drop-ins or
vhost in step with what the repo says they are, so "source of truth" headers on committed unit files
are a claim with nothing behind them. webbsite paid for that on 2026-09-11: Caddy's unit was tracked
in no repo at all, so nobody noticed it carried no `Restart=`, and one OOM kill became five days of
Cloudflare 521s while the app underneath answered every health check.

With `converge = true`, `deploy/converge.sh` from the app repo runs **as root**, after `uv sync` and
**before** the reload. A failure stops the deploy with the old code still serving and the edge cache
intact, exactly like a failed `uv sync`. If `deploy/converge.sh` exists but is not executable that is
also fatal — a forgotten `chmod +x`, not "this app has none": deploying while believing the config
converged is worse than not deploying.

The app owns the script, because only it knows which files it declares. Keep a fixed
destination allowlist in it so a stray file cannot become a live unit by accident, validate anything
a daemon has to parse *before* installing it, and make it silent when nothing changed — it runs
every two minutes.

> **Trust boundary.** A repo-declared unit's `ExecStart` runs as root, so on a converging box
> **merge access to the app repo is root access on that box.** That is the same bargain
> `dataguru-converge` makes and it is fine where it is already true, but it must be a deliberate
> per-app decision — which is why this is opt-in, and why it needs its own sudoers grant
> (`NOPASSWD: /srv/<app>/deploy/converge.sh`) rather than riding on the `systemctl` one.

`site.toml` wins over the environment, and a disagreement is **reported**, not silently resolved —
a box quietly behaving differently from the repo is the failure this exists to end. It is read
twice: once before the fetch (for knobs needed to decide what to do) and again after the merge, so
a commit that changes it governs its own deploy rather than the next one. A malformed file is fatal
*after* the merge and merely a warning before it, or the file that breaks the deploy would deadlock
the very commit that fixes it.

#### No `deploy/converge.sh`? `bin/converge.sh` — declare files instead of scripting them

An app with **no** `deploy/converge.sh` at all gets the toolkit's own engine instead, driven by a
`[converge]` table in `site.toml` — the shape webbsite's own hand-written `converge.sh` and
renavon-monorepo's `dataguru-converge.sh` had each already converged on independently: install a file
only on diff, validate before installing, reload with a rollback on failure, keep declared timers
enabled. An app with its own script keeps using it — this is the alternative for one that would
rather declare than script.

```toml
[[converge.files]]
src      = "deploy/app.service"          # relative to the app's repo
dst      = "/etc/systemd/system/app.service"
apply    = "daemon-reload"               # reload | restart | daemon-reload

[[converge.files]]
src      = "deploy/Caddyfile"
dst      = "/etc/caddy/Caddyfile"
validate = "caddy"                       # caddy | systemd-analyze | visudo
unit     = "caddy"                       # required iff apply is reload/restart
apply    = "reload"

[converge]
ensure_active = ["caddy"]   # started (once enabled) if found down, every tick
enable_timers = true        # every *.timer among the files above is enabled+started
prune         = true        # a dst this app installed before but no longer declares is deleted
```

- **Rollback.** A `reload`-apply file is backed up to `$dst.bak` before being overwritten; if the
  reload then fails, the backup is restored and reloaded again, and the run is still marked failed —
  the box is left exactly where it was, not merely "not worse".
- **The cold-start race**, ported from webbsite's own Caddy special case: if `ensure_active` had to
  *start* a unit this tick (it was found down), that fresh process already read whatever file was
  just installed. Reloading it immediately after is not merely redundant — it can lose a race with
  the daemon still coming up and report a failure that would roll back a file that was never wrong.
  A reload sharing a unit with one `ensure_active` just started is skipped, once, that tick only.
- **`prune`** is state-tracked (`/var/lib/<app>/converge-installed-files`), not a directory scan: a
  file the app never asked this engine to manage is never at risk just because it happens to sit near
  one that is.
- `bin/converge-config.py` reads the `[converge]` table; a malformed one (an unknown `apply`/
  `validate` value, `apply = "reload"` with no `unit`) refuses outright rather than silently doing
  nothing.

### Cloudflare as code: `bin/cf-converge.py`

Desired zone state lives in the app's own `deploy/cloudflare.json`, reviewed the same way as any
other repo change, and converged the same way anything else here is: automatically, idempotently,
and silently when nothing changed. Without this, a zone's SSL mode, its A records and its cache/WAF/
rate-limit rules are applied by hand from committed JSON — so a change in git reaches Cloudflare
only if a human remembers to curl it, which is how a cache rule can go missing on a zone while it
looks, from the origin, perfectly cacheable.

```json
{
  "ssl_mode": "strict",
  "dns": {"a_records": [{"name": "@", "proxied": true}, {"name": "www", "proxied": true}]},
  "cache_rules": [{"action": "set_cache_settings", "expression": "...", "enabled": true}],
  "waf_custom_rules": [],
  "rate_limit_rules": []
}
```

- **Absent means "this repo does not manage that phase"**; `[]` means "this phase must hold no
  rules". Each of the three rule phases is the declared list, in full — reconciling **is** replacing
  the phase entrypoint, not diffing rule-by-rule.
- **`__PUBLIC_IP__`** in any rule's text is substituted with the box's own derived public IP before
  comparison, so a WAF exemption for the box itself (`bin/cf-purge-verify.sh` fetches the public URL
  back *through* Cloudflare on every build) can be written once and stay correct as the box moves. An
  unresolved placeholder — including an *underivable* IP — **aborts that phase** rather than shipping
  a rule whose exemption silently never matches.
- **Phases are isolated**: one bad WAF expression fails only that phase; SSL, DNS and the other rule
  phases still converge, and the exit status still reflects the failure.
- **Dry-run is the default.** `--apply` is required to write anything.

**Shared zones — `rule_scope`.** Two apps can sit on subdomains of one Cloudflare zone. Without
opting in, each app's declared rule list would delete the other's rules on its very next tick — the
declared list *is* the phase, whole. Add a top-level key to opt one app's phases into naming their
own rules instead of owning the phase outright:

```json
{"rule_scope": {"host": "a.example", "shared_with": ["b.example"]}}
```

A phase then owns exactly the declared rules whose `expression` names `host`; any declared rule that
does not is refused and reported, never applied under the wrong scope. Rules found live that name
some *other* host are left untouched, in their original relative position — only the previously-owned
rules are replaced, as a block. A rule naming both this scope's host and a host outside
`shared_with` is ambiguous: refused and reported by name, same as one naming no scoped host at all.
`shared_with` is the "we agreed to co-own this one" escape hatch.

**Units.** `cf-converge@.service` (root, `--apply`) is started `--no-block` by the poller when a
deploy's fast-forward range touches `deploy/cloudflare.json` — not every tick, since an API
round-trip is not something a 2-minute poller should pay for when nothing declared changed.
`cf-drift@.timer` runs the same reconciler in dry-run daily, so a hand-edit at the dashboard is
caught even on a day nobody deploys; a reported diff pings `HEALTHCHECKS_CF_DRIFT_URL` the same way
a failure would, because drift **is** the failure mode that check exists to catch. Both are armed by
`host-converge.sh` iff `deploy/cloudflare.json` exists and `CF_CONFIG_TOKEN` is set in
`/etc/<app>/cf-env` — a declared file with no token nags instead (Cloudflare-as-code itself is
opt-in, so its total absence is not a nag).

`bin/cf-converge-run.sh` is the root wrapper the units call: it resolves the apex domain (site.toml's
`cf_domain`, or `CF_DOMAIN` in `cf-env`) and the box's own public IP (an override in
`/etc/site-deploy/host.env`, then cloud metadata, then an outbound echo — empty is safe, it just
leaves A-record content and any `__PUBLIC_IP__` rule untouched) and calls the pure, tested
`cf-converge.py` with them.

`CF_CONFIG_TOKEN` — a **single-zone** scoped token with DNS + cache-settings + zone-settings + WAF
edit and nothing else, notably not cache-purge (that is `CF_CACHE_PURGE_TOKEN`, used by
`bin/cf-purge.sh`) — lives in root-only `/etc/<app>/cf-env`, never in `/etc/<app>/env`: the poller
runs as the service user and has no business reading a token that can rewrite the zone's firewall.

**`bin/cf-purge.sh`** (unlike the config-write path above, this token lives in the ordinary
`/etc/<app>/env` — a cache-purge-only token is a much smaller blast radius). `CF_ZONE_ID` skips the
lookup; otherwise the zone is resolved from `BASE_URL`'s domain, the same name-filtered-list trick
`cf-converge.py` uses. `CF_PURGE_SETTLE` (default 3s) waits before purging, because the reload
immediately before it only *sends* SIGHUP — for a short window the old workers still answer, and
whatever the edge pulls in that window sits there for a full TTL. `bin/cf-purge-verify.sh` then
re-requests one URL and checks the edge actually let go of it: Cloudflare's purge API answers
`200 {"success": true}` whether or not anything was evicted, which is how a zone whose cache rule
quietly stopped admitting `PURGE` requests can log a clean purge every night for months. Promoted
from three near-identical app clones in renavon-monorepo; a fourth app's much larger *targeted*
purge (specific hub + sitemap URLs, harvested from the origin's own sitemap index) stays app-owned
rather than becoming a toolkit feature — this file purges everything, which is the common case.

### Off-box backup: `bin/backup.sh`

Opt-in by the **presence** of `deploy/backup-producer.sh` in the app's own repo — an executable that
writes backup content to stdout and exits cleanly (a `pg_dump`, a `sqlite3 .backup`, a tar of a data
directory: anything). The app declares WHAT to back up; this script owns HOW: `age`-encrypt, ship
with `rclone`, verify by round trip, prune to a fixed count, report. No `backup-producer.sh` is not
an error — most apps have no runtime state that outlives a redeploy.

```
"$PRODUCER" | age --encrypt --recipient $BACKUP_AGE_RECIPIENT
            | rclone rcat $BACKUP_RCLONE_DEST/<host>/<app>-<stamp>.age
            -> rclone cat (round-trip sha256, BEFORE the local copy is deleted)
            -> /var/lib/<app>/backup-last-success
            -> prune to BACKUP_KEEP_LAST, oldest first, this app's objects only
```

**Why the round trip matters, ported from renavon-monorepo's `dataguru-backup-state.py`:** an upload
that returned success is not a backup that can be read back. Its whole reason for existing was an
off-box tarball that went 13 days stale while every layer read green — the upload had never actually
been confirmed readable. The local ciphertext is not deleted until the round trip proves the remote
object matches it byte for byte; a mismatch fails the run loudly instead of silently trusting a
corrupt upload.

**Root, and a separate `/etc/<app>/backup-env`** — same reasoning as `cf-env`: a write-capable
object-storage credential must not sit in the environment of a public-facing gunicorn. The producer
script also runs as root, which is what lets it read state it does not own by construction (a WAL
database under another user's directory) with no bespoke grant.

```
BACKUP_AGE_RECIPIENT=age1...     # the age PUBLIC key; only this key can decrypt
BACKUP_RCLONE_DEST=<remote>:<bucket>/<prefix>   # an rclone remote already configured on the box
BACKUP_KEEP_LAST=14              # optional, default 14
HEALTHCHECKS_BACKUP_URL=...      # optional; a dead-man switch a silently-stopped backup deserves
```

`host-converge.sh` arms `site-backup@<app>.timer` (daily) iff `backup-producer.sh` exists AND both
required vars are set; a declared producer with no credentials nags instead of silently not backing
up. `age` and `rclone` are not in the fleet's base `host/packages.txt` (most apps need neither) — an
app that opts in adds them to its own `deploy/packages.txt`, the same mechanism an app already uses
for a native library dependency.

### Reference units: `systemd/app@.service`, `systemd/site-build@.service`

Unlike every other unit in this repo, these two are **not** installed or converged automatically —
they are what an app's own unit usually started from, kept here reviewed and tested so an app can
copy or diff against them rather than re-derive the hardening block and the build-unit's ExecStopPost
chain from scratch. `systemd/app@.service` is a reference gunicorn unit (`--no-control-socket` and
why it outlives the fd leak it was originally added for, `ExecReload=` SIGHUP for graceful worker
rotation). `systemd/site-build@.service` is the reference for a `DEPLOY_BUILD_SERVICE` build unit:
reload the app onto the new build, then purge — and skip the purge, loudly, if the reload failed,
because purging while the origin still serves the OLD build just refills the edge from stale content
on a fresh TTL. `tests/test-systemd-units.sh` pins the ordering (`-+` reload, then a `-`-prefixed
`/fail` ping, then the un-prefixed purge LAST so its `exit 1` can fail the unit), the marker
handshake between the privileged reload step and the sandboxed steps after it, and the two systemd
text transforms that fail silently: an unresolved `%` specifier (systemd drops the whole
`ExecStopPost=` directive) and a single-`$` `${...}` (systemd resolves it itself, to nothing, before
the shell ever sees it — write `$${...}` for a form the shell resolves instead).

**The canonical hardening block**, reused verbatim by both of the above and by `site-backup@.service`:
```
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=yes
LockPersonality=yes
SystemCallArchitectures=native
ProtectClock=yes
ReadWritePaths=<whatever this unit actually writes>
```
`ReadWritePaths=` is the one line that must be reasoned about per unit, not copied blind — and reading
a WAL SQLite database can itself require creating its `-shm` file if no writer currently has one open,
which is not a read-only filesystem operation despite being a "read".

## Monitoring: two checks per app, and why neither is enough alone

Nothing here reports a success it has not verified, and a missing dead-man does not fail — it
just never speaks. So both halves are opt-in by env *name* in `/etc/<app>/env`, and `install.sh`
nags loudly when either is absent.

**The deploy dead-man** (`HEALTHCHECKS_DEPLOY_URL`). The subject is *"this box is at the ref it
should be at"*, not *"a tick ran"*: a ran-dead-man is green during the failure it most needs to
catch, a fetch that has failed every two minutes for a week. The poller pings the check root on
every level tick, `/start` when a deploy begins, and `/fail` from one `EXIT` trap on any failed
step (body: the tick's log lines), or after 15 min of being unable to fetch. The unit's
`ExecStopPost` (`hc-unit-result.sh`) covers the script being killed before its trap. Size the check
600 s / grace 900 s: a dead poller, disabled timer or dead box goes DOWN inside 25 min; a failed
deploy pages immediately.

**The active probe** (`PROBE_URL` → `HEALTHCHECKS_PROBE_URL`, `site-probe@<app>.timer`, every
5 min). Curls the app's *public* health URL through the edge — the user's vantage point — and pings
root or `/fail` with the evidence. `http_probe` absorbs one blip of any class (`--retry-all-errors`,
because plain `--retry` skips DNS flaps, refused connections and Cloudflare 52x). Point it at the
deep variant where the app has one. Size the check 300 s / grace 600 s. A dead box cannot probe,
but a dead box also stops pinging, so the check goes DOWN at timeout+grace: both failure classes
are covered. Pings are leaves (`lib/hc.sh`): they never change an exit code and never become a
dependency of the work they report on.

**The alarm-armed sweep** (`HEALTHCHECKS_API_KEY` + `HEALTHCHECKS_SWEEP_TAG` in a root-only
`/etc/<app>/ops-env`, `site-checks-armed@<app>.timer`, every 15 min). healthchecks accepts a ping
to a *paused* check, answers 200, and discards it, so every layer on every box reports success
while the alarm is gone. This sweeps every check carrying the tag and fails if the sweep is shorter
than `HEALTHCHECKS_EXPECTED_MIN` (an empty sweep must never pass vacuously), if any check is
paused, or if a simple-period check is silently stale. A `down` check is *armed and firing*, never
a violation. Tag its own check with the sweep tag and it asserts over itself. Size 900 s / 900 s.

## `deploy/required-env.txt`: the box has its config, and the app has it too

On a fleet of cattle, "rebuilt from nothing" is the normal case, and a rebuilt box that is missing
half its env file serves 200s all day: an unset knob usually hides a feature *by design*. The app
declares the env **names** it needs (values never leave the box), and `bin/env-check.sh <app>`
asserts them on install and whenever an invariants job asks:

```
# file        NAME             grade[@fresh]   what breaks without it
env           SECRET_KEY       required        the app
env           SENTRY_DSN       blank-ok        opt-in; blank and absent are the same to the code
env           POOL_SIZE        optional        default applies only when ABSENT; blank is int("")
env           CF_CACHE_PURGE_TOKEN required@fresh  cf-purge.sh re-reads the file each run
refresh-env   R2_KEY           required        the loader
```

- `file` is relative to `/etc/<app>/`; `env` is the app unit's `EnvironmentFile`.
- **Blank is not absent.** `os.getenv(name, default)` falls back only when the name is *absent*,
  so `POOL_SIZE=` is `int("")`. `required` must be present and non-blank; `optional` may be
  absent but blank is reported; `blank-ok` is never reported.
- **Both directions.** A name on the box that the manifest does not declare is a failure, so a
  knob cannot exist only in `/etc`.
- **The file is not the process.** systemd reads `EnvironmentFile=` at unit *start* and a reload
  is SIGHUP, so a restored file turns the check green while the app keeps serving what it booted
  with. When `env` is newer than the unit start, `/proc/<MainPID>/environ` is compared
  variable-by-variable (in-process, never printed), skipping `@fresh` names whose only readers
  re-read the file each run.
- Exit 0 clean, 1 config wrong, **2 the checker could not run**. BLIND is never clean.

## Secrets (`/etc/<app>/env`, box-local — never in this repo)
```
DEPLOY_RELOAD=reload               # or: restart   (apps with no ExecReload)
DEPLOY_UV_ARGS=--frozen --no-dev   # or just: --frozen
# DEPLOY_BUILD_SERVICE=<app>-build.service   # snapshot-backed apps only (see above)
# CF_CACHE_PURGE_TOKEN=... / CF_ZONE_ID=... / BASE_URL=...  # optional edge purge (see below)
# HEALTHCHECKS_DEPLOY_URL=...                 # deploy dead-man (see Monitoring)
# PROBE_URL=... / HEALTHCHECKS_PROBE_URL=...  # active probe (see Monitoring)
```

`/etc/<app>/cf-env` (root:root 0440, separate file — the service user reads `env` but not this) holds
`CF_CONFIG_TOKEN` for `bin/cf-converge.py` (see "Cloudflare as code" above): a single-zone token
that can rewrite DNS/WAF/cache is a different blast radius than the cache-purge token above it, and
the poller that reads `env` every two minutes has no business reading it.

## Bootstrap (per box, one-time)
```bash
APP=<app>
# 1. Clone the toolkit next to the app checkout, as root (root runs scripts out of it).
sudo git clone <this-repo-url> /srv/site-deploy
#    (private fork? clone over SSH with a read-only deploy key, like the app repo.)

# 2. Add the DEPLOY_* knobs (see example.env) to /etc/$APP/env.

# 3. Install + enable. The first tick deploys whatever the box is behind by.
/srv/site-deploy/bin/install.sh "$APP"
journalctl -fu "site-deploy@$APP.service"
```
Toolkit updates land automatically: `site-deploy-update.timer` fast-forwards `/srv/site-deploy`
onto `origin/ci-green` every ~2 min (see above). `journalctl -u site-deploy-update` is silent
when current and loud when it refuses.

## Tests

```sh
./tests/test-auto-deploy.sh
./tests/test-auto-deploy-workspace.sh
./tests/test-self-update.sh
./tests/test-hc.sh
./tests/test-env-check.sh
./tests/test-checks-armed.sh
./tests/test-host-converge.sh
./tests/test-ufw-cloudflare-sync.sh
./tests/test-cf-converge.sh
./tests/test-cf-converge-run.sh
./tests/test-cf-purge.sh
./tests/test-backup.sh
./tests/test-systemd-units.sh
./tests/test-converge-config.sh
./tests/test-converge.sh
./tests/test-fleet-config.sh
./tests/test-workspace.sh
./tests/test-site-config.sh
```

No network, no root, no systemd, no Cloudflare: a throwaway bare git origin stands in for GitHub,
and `systemctl`/`uv`/`curl` are stubs on `PATH` that record their arguments and can be told to fail.
Runs continue from each other's state, so idempotence is a real assertion.

Every guard is verified **by mutation** — break it and watch the named check fail. That is not a
formality: it caught that the CSS floor and ratio guards overlapped, so a single collapse scenario
pinned neither, and both could be deleted with the suite still green.

## Notes
- **No secrets in this repo.** Per-site tokens and knobs stay in `/etc/<app>/env` on each box.
- It doesn't replace a nightly snapshot-rebuild timer if you have one — they're independent.
- Requires: the box's `/srv/<app>` is a git checkout that can `git fetch` non-interactively (a
  read-only deploy key), a `uv` at `/usr/local/bin/uv`, and (for `reload`) an `ExecReload` in the
  app's own `.service`.
- Disable on a box: `sudo systemctl disable --now site-deploy@<app>.timer`.
