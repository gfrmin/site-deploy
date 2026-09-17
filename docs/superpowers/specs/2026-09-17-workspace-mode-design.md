# site-deploy: workspace mode (several apps from one checkout)

Design spec, approved 2026-09-17. Implements Phase D item 14 of the site-deploy extraction plan.

## Design

### Vocabulary

- **site** — a checkout: `/srv/<site>`, service user `<site>`, `site-deploy@<site>.timer`,
  `/etc/<site>/env` (the poller unit's EnvironmentFile: `HEALTHCHECKS_DEPLOY_URL`, single-app
  `DEPLOY_*`/`PORT`/`CF_*` fallbacks), `/var/lib/site-deploy/<site>` (StateDirectory: queues and
  stamps). Today site == app.
- **app** — a member the site serves, at `<apps_dir>/<app>/` in the checkout. Single-app site:
  one app, name == site, dir `.`. Workspace site: the apps `fleet.toml` lists for this host.
- **workspace mode** — a site whose `deploy/site.toml` has a `[workspace]` table.

### Declarations (three files, all in the site repo)

`deploy/site.toml` (site level; today's file, plus one table):

```toml
[deploy]                      # site-wide knobs, exactly as today
deploy_ref = "ci-green"
uv_args = "--frozen --no-dev"
tailwindcss_version = "4.3.3"
converge = true

[workspace]
apps_dir     = "apps"                            # members at apps/<app>/, each a uv workspace member named <app>
shared       = ["packages/"]                     # a change under here reloads every hosted app
build_inputs = ["packages/dataguru-core/src/"]   # a change under here rebuilds every hosted app's snapshot
```

`<apps_dir>/<app>/deploy/site.toml` (app level; the same `[deploy]` schema, per-app keys only):
`reload`, `service` (new), `build_service`, `build_inputs` (new), `port`, `health_path`,
`health_match`, `health_tries`, `css_min_ratio`, `cf_zone_id`, `cf_domain`; plus `[converge]`.
Site-only keys (`deploy_ref`, `uv_args`, `tailwindcss_version`, `converge`) in an app file are
ignored with one warning line — one checkout has one ref, one venv, one converge decision.

- `service` — the unit the poller reloads/restarts, the reload contract inspects, env-check
  compares against, and host-converge grants. Default `<app>.service` (single-app) or
  `<site>@<app>.service` (workspace; renavon's `dataguru@hkjcguru` for free).
- `build_inputs` — path prefixes relative to the app dir whose change dispatches
  `build_service`. Default `["data/build_db.py"]` (today's behaviour). renavon sets `["data/"]`
  per app and `packages/dataguru-core/src/` at site level (its #344 lesson: a directory fails
  open into one extra rebuild; an allow-list fails closed into a silently stale snapshot).

`deploy/fleet.toml` (which host runs what; exact `hostname` match, no fuzzy fallback — the
tailnet name and `hostname` can differ, and two app names can be one letter-order apart):

```toml
[hosts."box-a"]
apps = ["foo", "bar"]
[hosts."box-b"]
apps = ["baz"]
```

Override: `/etc/<site>/apps`, whitespace-separated, read whole (renavon's `read -a` stopped at
the first newline and silently never deployed an app on its own line). While present the
poller says so every tick. A host in neither: hosts nothing, says so every tick, syncs the whole
workspace, reloads nothing (renavon rule 2: ambiguity is not an answer).

Not ported: fleet.json `roles`/`exclusive_roles`. site-deploy's timers are env-gated per app, not
role-gated; renavon's publish/fulfil/healthchecks gates stay renavon's (plan, item 15).

### Identity in workspace mode (derived by host-converge, every tick)

- `/srv/<app>` → symlink to `/srv/<site>/<apps_dir>/<app>`. Absent: created + one line. Correct
  symlink: silent. A real directory or a symlink elsewhere: counted failure ("name collision").
  A symlink into this site's `<apps_dir>` for an app no longer hosted: removed, its alarm timers
  disarmed, one line. Only symlinks pointing into our own tree are ever touched.
- `/var/lib/<app>` root 0755 (converge manifest, backup stamp) if absent.
- Drop-in `/etc/systemd/system/site-probe@<app>.service.d/site-deploy.conf` and the same for
  `site-checks-armed@<app>` with `[Service] User=<site> Group=<site>` — the two units that run
  as `%i`. Root units (`cf-converge@`, `cf-drift@`, `site-backup@`) need nothing.
- `/etc/<app>/env` is `root:<site> 0640` (the poller reads `PORT`/`CF_*`/`BASE_URL` from it with
  `sed`, never sourcing); `cf-env`/`backup-env`/`ops-env` stay root-only as today.
- Never `site-deploy@<app>.timer`; the site's timer is the poller.

### The queue contract (`/var/lib/site-deploy/<site>/`, StateDirectory, owned by `<site>`)

- `pending/<app>` — "this app's apply is unfinished"; content `reload` or `restart`. Written by
  the poller at merge time for every app in scope (`restart` if `uv.lock` changed), and by
  converge.sh (as root) with `restart` when a template unit's directives changed. `restart` is
  never downgraded. Cleared only after that app's health probe passes. Dropped with a line when:
  the app is not hosted *and* the list is non-empty (an empty list must not delete state —
  renavon w); the app's `service` is not enabled, or is neither active nor failed (whatever
  starts it next execs the new unit — renavon o/p/q). Kept when the verb itself failed (r).
- `rebuild-pending/<app>` — empty flag: build inputs changed while a build was busy or another
  hosted app's build was running (one poller-started build per box). Drained in the EXIT trap at
  the end of every healthy tick (fetch, ref, sync, converge all OK), at most one dispatch per
  tick; not hosted → dropped with a line; a failed dispatch is kept and logged every tick.
- Single-app migration: the checkout markers `.site-deploy-build-pending` and
  `.site-deploy-reload-pending` are moved into the queue dirs on first sight, one line each.

### Poller (`bin/auto-deploy.sh`), tick shape after the change

1. Setup: `SITE=$APP`; source `lib/hc.sh`, `lib/workspace.sh`. Mode from the site `[workspace]`
   table; `APPS` from `ws_apps` (override → fleet.toml → none) or `($SITE)` with dir `.`.
2. Sweep stale markers (rules above). Ref, fetch, gate, frozen clock, level/behind reporting —
   unchanged. Up-to-date early exit unless a hosted app has a `pending/` marker.
3. `uv.lock` recovery, ancestor check, "deploying", `/start` — unchanged. `CHANGED` computed once
   before the merge. Per app `in_scope`: `^<dir>/`, `^uv\.lock$`, `^pyproject\.toml$`, `^deploy/`,
   each `[workspace].shared` prefix; single-app: always. Per app `cf_changed`:
   `<dir>/deploy/cloudflare.json`.
4. Merge (the resolved SHA), then write `pending/<app>` for every in-scope app.
5. Site config re-read (fatal). Sync: workspace → `uv sync $UV_ARGS --package <app>...` with
   renavon's three soft rules (a name whose `<apps_dir>/<app>/pyproject.toml` lacks
   `name = "<app>"` → unscoped + WARNING; empty list → unscoped + line; scoped failure → retry
   unscoped before giving up). Failure → "NOT reloading anything", exit 1, no drain.
6. Converge (`converge = true`, site level): the root-never-runs-a-dirty-tree check covers
   `deploy/` and `<apps_dir>/*/deploy/`; `host-converge.sh <site>`; site-level
   `deploy/converge.sh` | `bin/converge.sh <site>` (today's three-way rule); then per hosted
   app the same three-way rule on `<apps_dir>/<app>/deploy/` via `bin/converge.sh <app>`
   (through the symlink). Any failure → exit 1 before any verb.
7. Per app with a marker, in a subshell so knobs are scoped (app site.toml rendered by
   `site-config.py`, per-app-keys only; `PORT`/`CF_*` from `/etc/<app>/env` by `sed` in
   workspace mode, from the unit env in single-app mode): build inputs → queue-or-dispatch
   (busy = `is-active` ∉ {inactive, failed}; empty → WARNING, treat idle; one dispatch per box
   per tick via a tick-local file); CSS in the app dir (unchanged canary); reload contract on
   `service`; verb from the marker; health; clear marker; `bin/cf-purge.sh` with the app's env;
   `cf-converge@<app>` `--no-block` if `cf_changed`. A subshell failure leaves the marker and
   the loop continues.
8. End: `report_level "deployed …"` and `DRAIN_OK=1` only if no hosted app's marker remains;
   otherwise exit 1 (`on_exit` sends `/fail` with the tail of the run log). The EXIT trap drains
   `rebuild-pending/` when `DRAIN_OK=1`, including on the silent up-to-date path.

### `lib/workspace.sh` + `bin/fleet-config.py`

`ws_apps <srv> <site>` prints hosted app names (override file with a stderr nag, else
`fleet-config.py deploy/fleet.toml "${BOX_HOSTNAME:-$(hostname)}"`, else nothing and the reason
on stderr); `ws_apps_dir`, `ws_site_of <name>` (a `/srv/<name>` symlink into
`/srv/<site>/<apps_dir>/` names its site; anything else is its own site). Used by the poller,
host-converge, converge.sh, install.sh and the tests. `fleet-config.py` is stdlib tomllib,
prints one app per line, exit 0 with nothing when the host is absent, exit 1 on a malformed file
(safety-critical: malformed must never read as "hosts nothing").

### `bin/site-config.py`

New keys: `service` → `DEPLOY_SERVICE`, `build_inputs` → `DEPLOY_BUILD_INPUTS` (newline-joined);
`[workspace]` → `WORKSPACE_APPS_DIR`, `WORKSPACE_SHARED`, `WORKSPACE_BUILD_INPUTS`
(newline-joined). A `--app-keys` flag renders only the per-app subset (the poller's per-app read
and host-converge's `service`/`build_service` lookup use it).

### `bin/host-converge.sh <site>` in workspace mode

Reads `ws_apps`. Sudoers for user `<site>`: per app `reload`/`restart <service>`,
`start --no-block <build_service>`, `start --no-block cf-converge@<app>.service`,
`bin/converge.sh <app>`; site level: `host-converge.sh <site>`, `bin/converge.sh <site>`,
`/srv/<site>/deploy/converge.sh`. Per app: the symlink, `/var/lib/<app>`, the two drop-ins,
the env-gated alarm timers exactly as today keyed on `/etc/<app>/*`. Packages: base + site
`deploy/packages.txt` + each app's. needrestart `__APP__` = site (the `^<site>-` anchor already
covers `<site>-build@<app>` instances and excludes `<site>@<app>`). Prune symlinks/drop-ins/
timers for an app that left the list. `install.sh <site>` loops env-check over the apps with
`UNIT=<service>`.

### `bin/converge.sh` (four changes, both modes)

- A `unit` naming a template (`foo@.service` or `foo@`) with `apply = "restart"` cannot be
  restarted: converge.sh writes `restart` into `pending/<app>` for every hosted app whose
  `service` instantiates it (`ws_apps` of `ws_site_of "$APP"`), and says so. The poller applies
  it behind the CSS build (renavon #203: a restart in front of that guard put new templates live
  against a stale stylesheet). `apply = "reload"` on a template is a config error.
- Directives diff (renavon #1362): for a dst under `/etc/systemd/system/` with apply
  reload/restart, compare `unit_directives` (non-comment, non-blank lines) old vs new; a
  comment-only change is installed and daemon-reloaded, nothing bounced, one line says so.
- Latent gap: any changed dst under `/etc/systemd/` daemon-reloads before the reload/restart.
  Today `apply = "restart"` restarts against the *old* unit definition.
- Restarting a `*.timer` is gated on is-enabled *and* is-active (renavon #204: restarting a
  stopped `Persistent=true` timer fires its service immediately).

### Not in this design

Per-app `deploy_ref`/venv (one checkout, one lock); fleet roles; renavon's `healthchecks`,
publish/fulfil units, `scripts/new-app`, `dataguru-build.sh` (stays app-side); an
`ETC`/`APP_DIR` indirection (decision 2).

## Files

- `bin/auto-deploy.sh` (refactor: per-app function, queue dirs, scope, scoped sync),
  `bin/host-converge.sh`, `bin/converge.sh`, `bin/converge-config.py` (template validation),
  `bin/site-config.py`, `bin/install.sh`, `bin/env-check.sh` (`UNIT` from `service`)
- new: `lib/workspace.sh`, `bin/fleet-config.py`
- `systemd/site-deploy@.service`: `StateDirectory=site-deploy/%i` already exists; add
  `pending`/`rebuild-pending` subdirs to the comment, nothing else
- tests: `tests/test-auto-deploy.sh` (stays green; + migration, `service`, marker verbs),
  new `tests/test-auto-deploy-workspace.sh` (the port), new `tests/test-fleet-config.sh`,
  `tests/test-host-converge.sh` (+ workspace scenarios), `tests/test-converge.sh` (+ template
  queue, directives diff, daemon-reload, timer gate); `.github/workflows/tests.yml`
- `README.md`: new section "Workspace mode: several apps from one checkout" (vocabulary, the
  three files, override, identity, queue contract, exit rule, migration recipe for a
  renavon-shaped box); Layout table; Tests list. `example.env`: `/etc/<site>/apps` note.
- `docs/superpowers/specs/2026-09-17-workspace-mode-design.md`: this Design section, committed
  in PR 1.

## PR sequence (each: TDD, shellcheck clean, mutation-verified guards, README in sync, merged
when green; stacked PRs retargeted to `master` before a predecessor branch is deleted)

1. `phase-d-poller-apps` — commit the spec; refactor the poller's per-app tail into a function
   driven by `APPS=($SITE)`/dir `.`; queue dirs + marker verbs + migration; `service` and
   `build_inputs` knobs; drain in the EXIT trap gated on a healthy tick. Single-app only.
   **Tell the webbsite session before merging** — this changes the poller's on-box state files
   and reaches its box via `ci-green`; confirm its journal stays a silent no-op after.
2. `phase-d-workspace-lib` — `lib/workspace.sh`, `bin/fleet-config.py`, `[workspace]` and
   `--app-keys` in site-config.py, tests for each.
3. `phase-d-workspace-poller` — the per-app loop over `ws_apps`, diff scoping, scoped sync with
   the three soft rules, per-app env by `sed`, per-app converge; `tests/test-auto-deploy-workspace.sh`
   ported by group: queue a–j; restart queue k–r, r1–r6; two apps s–w; one build per box
   sb1–sb8; sync scope aq–av; build inputs ah–am; diff scoping pg1–pg5 (+ "site deploy/
   changed → every app"); fleet/override scenarios. Scenarios already covered by
   test-auto-deploy.sh for the shared path (CSS x*, health h*, gate y–af, lock an–ap, dead-man
   d*, fz*) are not duplicated. Exit-code divergence (decision 3) stated in the header.
4. `phase-d-host-converge-ws` — workspace mode in host-converge + install.sh; scenarios for
   symlink create/keep/collision/prune, drop-ins, per-app grants, no per-app deploy timer.
5. `phase-d-converge-queue` — converge.sh template-restart queue, directives diff,
   daemon-reload-before-restart, timer gate; converge-config validation.
6. `phase-d-docs` — README workspace section + migration recipe, example.env; then the two
   remaining item-15 renavon issues (`dataguru-deploy.sh`, `dataguru-converge.sh`), each naming
   what to delete, the `fleet.toml`/`site.toml`/env-rename migration, and the site-deploy paths.

