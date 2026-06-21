#!/bin/bash
set -euo pipefail

# =============================================================================
# closeout-allow-for-on-restart — close a leftover allow-for window at boot
# =============================================================================
# Runs inside a boxa container as root, invoked by init-firewall.sh at the
# very start of every container boot (before any iptables/ipset flushing).
#
# Reason this script exists: the teardown daemon owns the normal close path,
# but it dies on container restart. A live sentinel that survives restart
# (it lives on the bind-mounted `boxa-shared` volume) would otherwise leave
# a phantom "active window" forever, and the user would never get a
# notification with the harvest summary.
#
# Behaviour:
#   - No sentinel → exit 0 silently (the common case — every container boot
#     enters this path, allow-for windows are the exception).
#   - Sentinel present → run `allow_for::write_harvest_closeout interrupted`
#     to write a partial harvest log and drop a pending JSON for the host-side
#     notification. Then remove the sentinel.
#
# Mostly absent: ipset destroy, iptables -D, dnsmasq SIGHUP reload —
# init-firewall.sh is about to flush the entire chain and start dnsmasq
# fresh, so undoing the now-vanished kernel-side state would be a no-op
# at best and a misleading error at worst.
#
# One piece that DOES need explicit cleanup: the allow-for dnsmasq drop-in
# at /etc/dnsmasq.d/boxa-allow-for.conf. It lives on the container
# rootfs (survives `docker restart`), and init-firewall starts dnsmasq
# with `--conf-dir=/etc/dnsmasq.d`, which loads every *.conf in that
# directory. Without this rm, the post-restart dnsmasq would boot with
# stale `ipset=/#/harvest-pool` directives pointing at an ipset that no
# longer exists, so every lookup would log "ipset add failure" and the
# closed window would appear to still influence DNS resolution.
#
# The dnsmasq queries log lives in the container rootfs at
# /var/log/dnsmasq-queries.log. It survives `docker restart` (same container
# id, container fs preserved), so the harvest aggregation has real data on
# that path. On `boxa build` (stop + rm + run) the rootfs is fresh and
# the log is gone; the harvest writes "no non-allowlist domains" and the
# closeout still fires the notification so the user knows the window was
# torn down. Best-effort by design (ADR 0009).
# =============================================================================

# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=lib/allow-for.sh
source /usr/local/share/boxa/lib/allow-for.sh

if ! allow_for::sentinel_exists; then
    exit 0
fi

# Reason marker: both the "expired during restart" and "live window
# interrupted by restart" cases land here. The toast renderer maps
# `interrupted` to "interrupted by restart" (deliver-allow-for-notification.sh
# build_toast_body), which is accurate for both — the user's window is gone
# either way and the harvest summary is what matters.
# `|| true` is load-bearing: the harvest path can fail mid-flight (log dir
# unmounted on a partial install, mktemp out of inodes, etc.). `set -e`
# would otherwise abort before the stale-state cleanup below, and
# init-firewall masks our exit code — so a half-failed restart closeout
# would leave the stale dnsmasq drop-in AND a phantom sentinel behind,
# which is the exact failure mode this script exists to prevent. Harvest
# is best-effort; cleanup is mandatory.
allow_for::write_harvest_closeout "interrupted" || true

# Drop the stale dnsmasq drop-in before init-firewall starts dnsmasq —
# see header comment for the failure mode this guards against.
rm -f "$ALLOW_FOR_DNSMASQ_CONF"

# Sentinel removal mirrors do_teardown's tail: the file is the source of
# truth for "is a window active", and leaving a torn-down sentinel behind
# would make every subsequent `boxa allow-for` think a reset-clock is
# in order against state that no longer exists.
rm -f "$ALLOW_FOR_SENTINEL"
