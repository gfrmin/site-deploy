# Root never trusts the service user's checkout (issue #31, part 2)

## Boundary

The README's bargain: **merge access to an app repo may be root on a converging
box; an RCE in the app must not be.** `/srv/<site>` is the service user's home,
so the checkout, its `.git` (config, refs, hooks) and every file in it are
attacker-controlled once the app is compromised. Part 1 (#34) made
`host-converge` treat *declared values* as untrusted input. Part 2 removes the
places where root *executes or applies* checkout content:

| root consumer | today reads | risk |
|---|---|---|
| `sudo /srv/<site>/deploy/converge.sh` (granted to the service user) | the checkout's script | edit + `sudo` = root, immediately |
| `sudo bin/converge.sh <app>` (the `[converge]` engine) | checkout's `site.toml` + `src` files | installs any unit/file as root |
| `site-backup@` → `backup.sh` | runs checkout's `deploy/backup-producer.sh` as root | root exec daily |
| `cf-converge@`/`cf-drift@` → `cf-converge-run.sh` | checkout's `deploy/cloudflare.json` | app compromise rewrites DNS/WAF for the zone |

The `auto-deploy.sh` dirty-tree guard does not help: it compares against a HEAD
the attacker can commit to, and `remote.origin.url`/`refs/remotes` are theirs too.

## Design: a root-owned, verified tree

`bin/site-tree.sh` (root, toolkit-owned) is the only way root obtains app
content.

- **Pinned origin.** `/etc/site-deploy/origin/<site>` (root, 0644) holds
  `url=<clone URL>` and optionally `key=<ssh identity path>`. If absent,
  `host-converge` writes it **once** from the checkout's
  `remote.origin.url` (read with `git config --file`, which runs nothing),
  saying so loudly: trust on first use at the moment this ships, the same
  moment an admin would otherwise have to hand-write it. After that it is
  never re-read from the checkout; changing it is an admin act.
- **Root mirror.** `/var/lib/site-deploy-root/mirror/<site>.git`, bare, root-owned
  0700. Fetched by root from the pinned URL only, with a hermetic transport:
  `GIT_CONFIG_NOSYSTEM=1`, `HOME` pointed at a root-owned dir,
  `GIT_SSH_COMMAND='ssh -F /dev/null -o IdentitiesOnly=yes -o
  UserKnownHostsFile=/var/lib/site-deploy-root/known_hosts -o
  StrictHostKeyChecking=accept-new [-i key]'`, and `GIT_ALLOW_PROTOCOL=https:ssh`
  (git's `ext::` transport runs a command; a pinned URL is also shape-checked
  to `https://…`, `ssh://…` or `user@host:path`, never starting with `-`). The service user can at worst
  break authentication (a DoS, loud), never substitute content: the URL and
  the host key are root's.
- **Verification.** A requested SHA must be a 40-hex commit that is equal to
  or an ancestor of the mirror's `refs/heads/master`. That is exactly the
  merge-access bargain: anything on master is something a maintainer merged.
  (A gate ref such as `ci-green` only ever points at master commits.) The
  mirror is fetched only when the SHA is not already known and verified, so a
  steady-state tick costs no network.
- **Forward only.** A pin must be the current tree's commit or a descendant
  of it: deploys only fast-forward, and an older master commit would re-run an
  old hook and roll `current` back. After a history rewrite an admin removes
  `current`.
- **Store.** Everything lives under `/var/lib/site-deploy-root/`, never under
  `/var/lib/site-deploy/`, whose `<site>` directories belong to each site's
  poller (a site named `mirror` would otherwise own root's mirror).
- **Locking.** One `flock` per site: `pin` holds it exclusively (fetch,
  export, repoint, prune), and `converge` holds it shared while its hook runs,
  so a concurrent pin never prunes a tree in use.
- **Export.** `git archive <sha>` into `/var/lib/site-deploy-root/tree/<site>/<sha>/`
  (root-owned, 0755, built in a temp dir and renamed into place), and
  `/var/lib/site-deploy-root/tree/<site>/current` → that dir. Older trees are
  pruned (keep current + previous).
- **Interface.** `site-tree.sh pin <site> <sha>` (verify, export, repoint
  `current`; prints the tree path) and `site-tree.sh path <site>` (prints
  `current`, exits 1 if none). Only `pin` is granted to the service user.

## Consumers switch to the tree

- **Poller.** After a successful fast-forward (and on a resume), calls
  `sudo -n site-tree.sh pin <site> <REMOTE>`. On `converge = true` a pin
  failure is fatal to the tick (old code keeps serving, `/fail`), because the
  converge that follows needs it; otherwise it is logged and the tick goes on.
- **Converge hook.** The grant `/srv/<site>/deploy/converge.sh` is **removed**.
  The poller calls `sudo -n site-tree.sh converge <site> <sha>` (and per
  workspace app `… converge <site> <sha> <app>`), which pins, then runs
  `<tree>/[<apps_dir>/<app>/]deploy/converge.sh` if present and executable,
  else `bin/converge.sh` against the tree. Environment passes
  `SITE_TREE=<tree>` and `SRV=/srv/<site>` so a hook can tell its source tree
  from the live checkout; cwd is the tree.
- **`bin/converge.sh`'s template-restart queue** reads the app list and
  each app's service from the tree (`SITE_TREE`), allow-lists app names, and
  writes the poller's marker **as the site user** (`runuser`), because that
  queue lives in a directory the service user owns: a symlink planted there
  must never be followed by root.
- **`bin/converge.sh`** gains `--tree <dir>`: `site.toml` and every `src` are
  read from the tree. Invoked without it, it refuses (no root path reads the
  checkout).
- **`backup.sh`** runs `<current>/deploy/backup-producer.sh`; no current tree
  means "cannot back up" (a counted failure, `/fail`), never a fallback to the
  checkout.
- **`cf-converge-run.sh`** reads `cloudflare.json` and `site.toml` from
  `current`; no current tree → refuse, as with a missing domain today.
- **`host-converge`** keeps reading declarations from the checkout (validated
  by part 1; its effects are bounded to allow-listed grants, packages from the
  configured apt repos, and timers), writes the pinned origin once, and its
  sudoers grants become: systemctl verbs for owned units, `host-converge.sh
  <site>`, `site-tree.sh pin <site> *`, `site-tree.sh converge <site> *`.
  `bin/converge.sh` and `/srv/<site>/deploy/converge.sh` are no longer granted.

## Rollout and failure modes

- Ships via self-update to every box. First tick after it lands: host-converge
  pins the origin (loud line), writes new sudoers. The poller's next deploy
  pins a tree. A box whose root cannot fetch (private repo, no key) fails
  closed on `converge = true` with a message naming
  `/etc/site-deploy/origin/<site>` and `key=`; deploys on other boxes are
  unaffected.
- Known fleet: webbsite is a public https repo, so root fetches with no
  credentials.
- Residual risk, stated: if an attacker already controls the service user at
  the moment this ships, TOFU pins their URL. The pinned file is one line an
  admin can check.

## Tests

`tests/test-site-tree.sh`: a sandbox origin (file:// bare repo), a service-user
checkout whose `.git/config` and refs are tampered with; `pin` of a SHA on
master exports it; `pin` of a local-only commit, of a commit only on another
branch, or with a redirected `remote.origin.url` is refused; a tampered
checkout file never appears in the tree; `current` moves atomically; prune.
Consumers: the poller calls pin/converge with the deployed SHA (stubbed);
converge.sh refuses without `--tree`; backup/cf read only from `current`.
