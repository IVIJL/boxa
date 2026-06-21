#!/bin/bash
set -euo pipefail

# =============================================================================
# start-allow-for-window — open an Allow-for window (ADR 0009)
# =============================================================================
# Runs inside a boxa container as root, invoked from the host via
#   docker exec -u root <container> /usr/local/bin/start-allow-for-window <N> <container>
#
# Idempotent:
#   - If a window is already active, this is a *reset-clock*: rewrite
#     expires_at to "now + N min" and exit. The daemon picks up the new
#     deadline on its next heartbeat.
#   - If no window is active, set up firewall + dnsmasq + sentinel and fork
#     the teardown daemon.
#
# Arguments:
#   $1   minutes (positive integer, default 15 if empty)
#   $2   container name — for logging and the harvest log filename only;
#        ipset/dnsmasq are container-local so no resolution happens here.
# =============================================================================

# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=lib/allow-for.sh
source /usr/local/share/boxa/lib/allow-for.sh
# shellcheck source=lib/allowlist.sh
source /usr/local/share/boxa/lib/allowlist.sh

MINUTES="${1:-15}"
CONTAINER_NAME="${2:-unknown}"

# --- Argument validation -----------------------------------------------------
# Numeric check kept here even though docker-run.sh validates upstream — the
# script also runs from `boxa update` rescue paths and shouldn't trust its
# caller blindly. Reject anything other than a positive integer.
if ! [[ "$MINUTES" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: minutes must be a positive integer (got: '$MINUTES')" >&2
    exit 2
fi

# --- Runtime-state probe -----------------------------------------------------
# A sentinel alone doesn't guarantee a *working* window: a container restart
# runs init-firewall.sh, which flushes iptables and destroys ipsets, but
# leaves /etc/boxa-shared/.allow-for.state untouched (that's a bind-mount).
# If the runtime state is gone, taking the reset-clock fast path would lie
# to the user — sentinel says "active" while the firewall blocks everything
# outside the permanent allowlist.
#
# Probe all three runtime components. Any missing one forces fall-through
# to fresh setup, which rebuilds them cleanly and generates a new sentinel.
runtime_state_intact() {
    ipset list -n "$ALLOW_FOR_IPSET" >/dev/null 2>&1 \
        && iptables -C OUTPUT -m set --match-set "$ALLOW_FOR_IPSET" dst -j ACCEPT 2>/dev/null \
        && [ -f "$ALLOW_FOR_DNSMASQ_CONF" ]
}

# --- Reset-clock branch ------------------------------------------------------
# Sentinel + live runtime + not yet expired → just rewrite the deadline.
# The teardown daemon re-reads the sentinel each heartbeat (~5 s), so the
# clock effectively resets without daemon coordination.
#
# Sentinel + expired, or sentinel without runtime → fall through. The
# fresh-setup branch will tidy stale leftovers and start clean. We do NOT
# preserve the old started_at in that case because dnsmasq's query log has
# been reopened (the byte offset stored in the old sentinel is meaningless
# after a restart), so the harvest effectively starts now.
if allow_for::sentinel_exists && ! allow_for::is_expired && runtime_state_intact; then
    new_expires=$(allow_for::iso_plus_minutes "$MINUTES")
    # Atomic rewrite: build the new file in a sibling temp and rename.
    # In-place sed would briefly leave a half-written sentinel that a
    # racing daemon heartbeat could misread.
    tmp="${ALLOW_FOR_SENTINEL}.tmp.$$"
    awk -v new="$new_expires" '
        BEGIN { FS=OFS="=" }
        /^expires_at=/ { print "expires_at=" new; next }
        { print }
    ' "$ALLOW_FOR_SENTINEL" > "$tmp"
    chmod 0644 "$tmp"
    mv "$tmp" "$ALLOW_FOR_SENTINEL"
    echo "Allow-for window extended: now expires at $(allow_for::human_time "$new_expires")"
    exit 0
fi

# --- Fresh-setup branch ------------------------------------------------------

# Clean up any stale state from an expired-but-not-cleaned sentinel.
# Defensive only — the teardown daemon owns the cleanup path, but a crashed
# daemon could leave the ipset/iptables/dnsmasq conf behind.
#
# Order matters: iptables rule first, ipset second. `ipset destroy` refuses
# to drop a set that's still referenced by an active rule, so reversing
# this would leave the set behind and the subsequent `ipset create` below
# would abort under `set -e`.
rm -f "$ALLOW_FOR_SENTINEL" "$ALLOW_FOR_DNSMASQ_CONF"
iptables -D OUTPUT -m set --match-set "$ALLOW_FOR_IPSET" dst -j ACCEPT 2>/dev/null || true
ipset destroy "$ALLOW_FOR_IPSET" 2>/dev/null || true

# Create the ipset BEFORE the iptables rule that references it — iptables
# refuses to add a `--match-set` rule against a nonexistent set.
ipset create "$ALLOW_FOR_IPSET" hash:net

# Insert the harvest-pool ACCEPT rule immediately before the final
# catch-all REJECT. init-firewall.sh produces an OUTPUT chain that
# contains multiple REJECTs:
#   - Docker DNS guard (REJECT to 127.0.0.11)
#   - DNS pinning (REJECT udp/tcp dpt 53/853)
#   - catch-all final REJECT                <-- target
#
# Parsing `iptables -L -n` is fragile: iptables-nft renders the protocol
# column as a number (`0` for all) while iptables-legacy prints `all`,
# and the column count differs subtly between versions. Use `iptables -S`
# instead — it dumps rules in restorable `-A` syntax with a stable
# canonical flag order, independent of the kernel backend. The catch-all
# is the single line shaped exactly `-A OUTPUT -j REJECT --reject-with...`
# (no `-d`/`-s`/`-p`/`-m` qualifiers before `-j`). Counting `-A OUTPUT`
# lines gives the 1-based rule number used by `iptables -I OUTPUT <N>`.
# Take the last match defensively in case anything ever adds a second
# such REJECT — the catch-all is appended last by design.
reject_line=$(iptables -S OUTPUT 2>/dev/null \
    | awk '
        /^-A OUTPUT/ { n++ }
        /^-A OUTPUT -j REJECT --reject-with/ { last=n }
        END { if (last) print last }
    ')
if [ -z "$reject_line" ]; then
    echo "ERROR: could not locate final OUTPUT REJECT rule — firewall in unexpected state" >&2
    ipset destroy "$ALLOW_FOR_IPSET" 2>/dev/null || true
    exit 1
fi
iptables -I OUTPUT "$reject_line" -m set --match-set "$ALLOW_FOR_IPSET" dst -j ACCEPT

# Tell dnsmasq to route every A/AAAA answer into the harvest pool.
# The empty domain in `ipset=//harvest-pool` is the catch-all form;
# combined with the existing per-allowlist rules in boxa-runtime.conf,
# every successful lookup populates either the permanent or the ephemeral
# set (and usually both — harmless).
cat > "$ALLOW_FOR_DNSMASQ_CONF" <<EOF
# boxa allow-for window — populated by start-allow-for-window
# Removed at window teardown. Do not edit by hand.
ipset=/#/${ALLOW_FOR_IPSET}
EOF
chmod 0644 "$ALLOW_FOR_DNSMASQ_CONF"

# Restart dnsmasq so the catch-all directive takes effect. Reuse the
# existing reload script — it already handles the SIGTERM/SIGKILL dance
# and PID file cleanup. The plain reload also regenerates the runtime
# allowlist conf, which is wasted work here but cheap and keeps the
# script the single source of truth for "how do I restart dnsmasq".
if ! /usr/local/bin/boxa-firewall-reload; then
    echo "ERROR: dnsmasq restart failed — rolling back" >&2
    rm -f "$ALLOW_FOR_DNSMASQ_CONF"
    iptables -D OUTPUT -m set --match-set "$ALLOW_FOR_IPSET" dst -j ACCEPT 2>/dev/null || true
    ipset destroy "$ALLOW_FOR_IPSET" 2>/dev/null || true
    exit 1
fi

# Capture the current byte length of the queries log. Teardown reads from
# this offset onward to extract just-this-window queries. Robust against
# log rotation as long as nothing rotates mid-window (dnsmasq is the only
# writer, and we just restarted it; the file is fresh-opened in append
# mode so the offset is stable).
LOG_START_BYTE=0
if [ -f "$ALLOW_FOR_DNSMASQ_QUERIES" ]; then
    LOG_START_BYTE=$(wc -c < "$ALLOW_FOR_DNSMASQ_QUERIES" | tr -d ' ')
fi

STARTED_AT=$(allow_for::now_iso)
EXPIRES_AT=$(allow_for::iso_plus_minutes "$MINUTES")

# Fork the teardown daemon BEFORE writing the sentinel — but we need the
# PID inside the sentinel. Two-step write: write sentinel without PID,
# fork, then patch in the PID. The daemon's first action is to wait until
# its sentinel is fully present, so this ordering is safe.
#
# `setsid` detaches from the controlling terminal (the docker exec
# session) so SIGHUP on exec-exit doesn't kill the daemon. nohup belt +
# braces. Stdin/out/err redirected so the daemon has no open fds onto the
# transient exec session.
cat > "$ALLOW_FOR_SENTINEL" <<EOF
started_at=${STARTED_AT}
expires_at=${EXPIRES_AT}
container=${CONTAINER_NAME}
daemon_pid=0
log_start_byte=${LOG_START_BYTE}
EOF
chmod 0644 "$ALLOW_FOR_SENTINEL"

# Belt-and-braces for old containers that predate the Phase 1 host-state
# bind mount: ensure the daemon's log directory exists before the
# shell-redirect tries to open it. Without this, an ENOENT here cancels
# the redirect AND the setsid command silently, leaving a sentinel with
# a garbage PID and no daemon to fire teardown.
mkdir -p "$(dirname "$ALLOW_FOR_DAEMON_LOG")" 2>/dev/null || true

setsid nohup /usr/local/bin/teardown-allow-for-window \
    </dev/null >>"$ALLOW_FOR_DAEMON_LOG" 2>&1 &
DAEMON_PID=$!
disown "$DAEMON_PID" 2>/dev/null || true

# Sanity-check that the daemon actually started. A failed redirect or
# missing binary would have produced a phantom PID; without this guard,
# the window would silently never close.
sleep 0.2
if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
    echo "ERROR: teardown daemon failed to start — rolling back" >&2
    rm -f "$ALLOW_FOR_SENTINEL" "$ALLOW_FOR_DNSMASQ_CONF"
    iptables -D OUTPUT -m set --match-set "$ALLOW_FOR_IPSET" dst -j ACCEPT 2>/dev/null || true
    ipset destroy "$ALLOW_FOR_IPSET" 2>/dev/null || true
    /usr/local/bin/boxa-firewall-reload >/dev/null 2>&1 || true
    exit 1
fi

# Patch the daemon PID into the sentinel via atomic rename.
tmp="${ALLOW_FOR_SENTINEL}.tmp.$$"
awk -v pid="$DAEMON_PID" '
    BEGIN { FS=OFS="=" }
    /^daemon_pid=/ { print "daemon_pid=" pid; next }
    { print }
' "$ALLOW_FOR_SENTINEL" > "$tmp"
chmod 0644 "$tmp"
mv "$tmp" "$ALLOW_FOR_SENTINEL"

echo "Allow-for window opened: expires at $(allow_for::human_time "$EXPIRES_AT") (daemon pid ${DAEMON_PID})"
