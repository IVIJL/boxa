#!/bin/bash
set -euo pipefail

# =============================================================================
# teardown-allow-for-window — close an Allow-for window (ADR 0009)
# =============================================================================
# Runs inside a boxa container as root. Two modes:
#
#   daemon   (no args)  — heartbeat loop; tears down when sentinel expires.
#                         Forked by start-allow-for-window and detached via
#                         setsid so the docker-exec session exit doesn't kill it.
#   immediate (--now)   — invoked by `boxa allow-for --stop`. Kills the
#                         daemon first, then runs the teardown right away.
#
# A teardown writes the harvest log, reverses the firewall changes,
# deletes the sentinel, and drops a notification request file for the
# host-side delivery script (Phase 3).
# =============================================================================

# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=lib/allow-for.sh
source /usr/local/share/boxa/lib/allow-for.sh

MODE="daemon"
HEARTBEAT_SECONDS=5
LOCK_FILE="/var/run/boxa-allow-for.lock"

case "${1:-}" in
    --now)   MODE="now" ;;
    --help|-h)
        sed -n '4,18p' "$0"
        exit 0
        ;;
    "")      MODE="daemon" ;;
    *)
        echo "ERROR: unknown argument '$1' (expected: --now or empty)" >&2
        exit 2
        ;;
esac

# --- Teardown core -----------------------------------------------------------
# Single source of truth for "close the window". Called by both modes under
# the flock; reads everything from the sentinel that exists at call time.
#
# $1: reason marker written into the harvest log header. One of
#     "expired"     — normal end-of-window, daemon path.
#     "stopped"     — user ran `--stop`.
#     "interrupted" — sentinel was already expired when daemon woke (e.g.
#                     container was paused / clock jumped).
do_teardown() {
    local reason="$1"

    # Harvest log + pending JSON publish — pure data path, shared with
    # the restart-closeout entry in init-firewall (see
    # closeout-allow-for-on-restart). Helper handles all sentinel-field
    # reads and best-effort error paths internally.
    allow_for::write_harvest_closeout "$reason"

    # Reverse the firewall state in setup order's mirror image. Each step
    # is best-effort: if init-firewall already cleaned up (rare path
    # through container restart), we still want the sentinel removed.
    rm -f "$ALLOW_FOR_DNSMASQ_CONF"
    /usr/local/bin/boxa-firewall-reload >/dev/null 2>&1 || true
    iptables -D OUTPUT -m set --match-set "$ALLOW_FOR_IPSET" dst -j ACCEPT 2>/dev/null || true
    ipset destroy "$ALLOW_FOR_IPSET" 2>/dev/null || true

    rm -f "$ALLOW_FOR_SENTINEL"
}

# --- Immediate mode ----------------------------------------------------------
# `--stop`: kill the daemon (it owns the heartbeat sleep) so it can't race
# with our teardown, then run teardown under the lock. If no sentinel
# exists, this is a no-op success — the user expected the window closed,
# and it is.
if [ "$MODE" = "now" ]; then
    if ! allow_for::sentinel_exists; then
        echo "No active allow-for window."
        exit 0
    fi

    daemon_pid=$(allow_for::get_field daemon_pid || echo "0")
    if [ -n "$daemon_pid" ] && [ "$daemon_pid" != "0" ] && kill -0 "$daemon_pid" 2>/dev/null; then
        kill "$daemon_pid" 2>/dev/null || true
        # Brief wait so the daemon actually exits before we touch its
        # state. 1 s is plenty given the 5 s heartbeat (the daemon
        # spends most of its time in sleep, which exits immediately on
        # SIGTERM).
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            kill -0 "$daemon_pid" 2>/dev/null || break
            sleep 0.1
        done
    fi

    exec 9>"$LOCK_FILE"
    flock 9
    # Re-check under the lock: the daemon may have completed its own
    # teardown between our sentinel check and the kill (or our kill may
    # have arrived just as the daemon was already exiting normally).
    # Without this, we'd write a phantom harvest log with "unknown"
    # fields.
    if ! allow_for::sentinel_exists; then
        echo "Allow-for window already closed."
        exit 0
    fi
    do_teardown stopped
    exit 0
fi

# --- Daemon mode -------------------------------------------------------------
# Loop: re-read the sentinel every heartbeat (5 s) so reset-clock updates
# take effect quickly and `--stop` can interrupt by deleting the sentinel
# out from under us. Exit cleanly if the sentinel disappears (another
# teardown raced ahead).
#
# SIGTERM from `--stop` exits the loop immediately because `sleep` returns
# non-zero on signal; we don't `wait` on the sleep, so the trap-less default
# is sufficient.
while allow_for::sentinel_exists; do
    if allow_for::is_expired; then
        exec 9>"$LOCK_FILE"
        flock 9
        # Re-check under the lock: an `--stop` invocation could have
        # taken the lock and finished teardown while we were waiting.
        allow_for::sentinel_exists || exit 0
        do_teardown expired
        exit 0
    fi
    sleep "$HEARTBEAT_SECONDS"
done
