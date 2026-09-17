#!/usr/bin/env bash
# Promoted from dataguru's deploy/host/harden.sh, which was already generic:
# the only thing that named dataguru was the drop-in filename. Unchanged
# otherwise, including the reasoning, which was hard-won.
# Lock down a site host: key-only sshd + a ufw firewall that allows only the
# tailnet and Cloudflare's IP ranges on the web ports. Run as root — and ONLY
# after confirming `ssh g@<box>` works over Tailscale SSH, because this closes
# public :22. (Tailscale SSH bypasses sshd/:22, so it keeps working.)
set -euo pipefail

# sshd: key-only, no root login (defense in depth). Written as a FIRST-match
# drop-in (00-*), NOT by editing the main sshd_config: cloud images frequently
# set PermitRootLogin/PasswordAuthentication in their own drop-ins, and sshd
# obeys the FIRST occurrence, so a low-numbered drop-in wins regardless of what
# the base image ships (a plain sed on the main file would silently miss it).
# Validate with `sshd -t` before reloading so a typo can't wedge sshd.
install -d -m0755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/00-site-harden.conf <<'SSHD'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
SSHD
chmod 0644 /etc/ssh/sshd_config.d/00-site-harden.conf
sshd -t && { systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true; }

# ufw: deny inbound by default; allow the tailnet; allow Cloudflare's CURRENT
# ranges on 80/443, kept in step daily by ufw-cloudflare-sync.timer (enabled
# below — its unit files are already on the box, installed by host-converge.sh
# during install.sh, which per the bootstrap order runs before this script).
# The origin only ever needs Cloudflare, so this closes the direct-to-origin
# path that would bypass Cloudflare's WAF/DDoS/cache. reset+deny+tailnet
# happens ONCE here; the Cloudflare rules themselves are the sync script's
# job even on this first run, so day-one and every day after use the same
# code path.
ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow in on tailscale0 >/dev/null
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$SELF/../bin/ufw-cloudflare-sync.sh"
ufw --force enable >/dev/null
systemctl enable --quiet --now ufw-cloudflare-sync.timer

echo "hardened: sshd key-only + ufw up ($(ufw status | grep -c ALLOW) allow rules = tailnet + Cloudflare 80/443)"
echo "VERIFY NOW from another shell:  ssh g@<box>   AND   curl -fsS https://<domain>/health"
