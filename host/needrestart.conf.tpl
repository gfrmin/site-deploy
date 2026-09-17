# Managed by site-deploy host-converge — edits on the box are overwritten each tick.
# Perl, parsed after /etc/needrestart/needrestart.conf.
#
# unattended-upgrades runs needrestart from its apt hook, and needrestart
# `systemctl restart`s every unit still mapping a library the upgrade replaced.
# A batch job — a snapshot rebuild, a data refresh: __APP__-*.service, Type=oneshot
# — that is running when libc or libpython upgrades is therefore STOPPED (SIGTERM,
# status 143) and started again from scratch, wasting up to an hour of CPU and
# delaying the data; the NEXT timer tick picks up the new library on its own.
#
# __APP__.service itself (gunicorn) stays ELIGIBLE on purpose: restarting a
# long-lived server onto a patched libc is the whole point of needrestart, and
# under systemd the stop is graceful. The regex is anchored on the hyphen so it
# cannot match the app unit — widening it to ^__APP__ would silence that too.
$nrconf{override_rc}{qr(^__APP__-)} = 0;
