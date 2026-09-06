#!/usr/bin/env bash
# Provision a site host: system packages + uv + service user + swap. Idempotent,
# safe to re-run. Run as root, once /srv/site-deploy and /srv/<app> are cloned.
#
#   bash /srv/site-deploy/host/provision.sh <app>
#
# Promoted from dataguru's deploy/host/install.sh. What was left behind: the
# shared-workspace `uv sync` (a uv WORKSPACE with four apps under one lock is
# dataguru's shape, not the fleet's) and the multi-app /etc/dataguru/apps
# bootstrap. What came across is everything that is true of any box.
#
# Does NOT touch the firewall or sshd — that is harden.sh, and it must run only
# AFTER `ssh g@<box>` is confirmed working over Tailscale SSH.
#
# Note bin/install.sh is a different thing: it installs the systemd template
# units and the sudoers grant for one app. This provisions the machine.
set -euo pipefail

APP=${1:?usage: provision.sh <app>}
SRV="/srv/${APP}"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DEBIAN_FRONTEND=noninteractive

# --- system packages: the half uv can't do (native libs + tools) -------------
# Caddy ships from its own apt repo; add it once if requested and absent.
if grep -qxF caddy "$SELF/packages.txt" && ! command -v caddy >/dev/null 2>&1; then
  apt-get install -y -q debian-keyring debian-archive-keyring apt-transport-https curl >/dev/null
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    > /etc/apt/sources.list.d/caddy-stable.list
fi
apt-get update -q
# An app may declare extra native packages of its own; the fleet baseline must
# not carry one app's LightGBM dependency onto every other box.
PKG_FILES=("$SELF/packages.txt")
[ -f "$SRV/deploy/packages.txt" ] && PKG_FILES+=("$SRV/deploy/packages.txt")
grep -hvE '^\s*#|^\s*$' "${PKG_FILES[@]}" | sort -u | xargs apt-get install -y -q

# --- uv (system-wide) --------------------------------------------------------
if ! command -v /usr/local/bin/uv >/dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 sh
fi

# --- service user + dirs -----------------------------------------------------
# One name for the user, the directory, the systemd instance and the env file.
# auto-deploy.sh assumes it, and the unit templates enforce it (User=%i).
id "$APP" >/dev/null 2>&1 \
  || useradd --system --create-home --home-dir "$SRV" --shell /usr/sbin/nologin "$APP"
install -d -o root -g root -m0755 "/etc/${APP}"
install -d -o root -g root -m0755 /etc/caddy/sites /etc/caddy/certs
install -d -o "$APP" -g "$APP" -m0755 "$SRV/.uv-cache"

# --- swap --------------------------------------------------------------------
# DO droplets ship with none. On 2026-08-24 a 7.8 GiB box with no swap had the
# kernel OOM-kill a build mid-promote AND SIGKILL a live web worker two minutes
# later, which Caddy served as 502s (dataguru RCA #287). Swap does not make an
# oversized job fit; it gives the kernel somewhere to put cold anonymous pages
# instead of reaching for the OOM killer on a transient spike.
if [ -z "$(swapon --show=NAME --noheadings)" ]; then
  if [ ! -e /swapfile ]; then
    fallocate -l 4G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=4096
    chmod 0600 /swapfile
    mkswap /swapfile >/dev/null
  fi
  # Non-fatal on purpose: under `set -e` a bare `swapon` aborts the whole
  # installer before the user and dirs exist — and it CAN fail on a re-run, on
  # an existing but unformatted /swapfile (a killed fallocate). Losing swap is
  # worth a warning; losing provisioning is not.
  if swapon /swapfile; then
    echo "provision: enabled 4G /swapfile"
  else
    echo "provision: WARNING /swapfile exists but swapon failed; no swap on this box" >&2
  fi
fi
# Gated on the file existing, not on the block above having run: a box that
# already had swap under a different name must not get an fstab entry for a
# /swapfile nobody created, or the next boot's `swapon -a` fails on it.
if [ -e /swapfile ]; then
  grep -qxF '/swapfile none swap sw 0 0' /etc/fstab \
    || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
# swappiness=10, not the default 60: a serving box's hot set is page cache, which
# is cheap to re-read, so evicting the app's anonymous memory to hold more of it
# is precisely backwards.
install -m0644 /dev/stdin /etc/sysctl.d/60-site-swappiness.conf <<'SYSCTL'
vm.swappiness = 10
SYSCTL
sysctl -q -p /etc/sysctl.d/60-site-swappiness.conf

echo "provision: $APP ready. Next: /etc/${APP}/env, then bin/install.sh ${APP},"
echo "           then CONFIRM tailscale ssh, then host/harden.sh."
