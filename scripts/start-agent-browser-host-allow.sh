#!/bin/bash
set -euo pipefail

# =============================================================================
# start-agent-browser-host-allow — session-scoped firewall exception for CDP
# =============================================================================
# Runs inside a boxa container as root, invoked from the host via
#   docker exec -u root <container> /usr/local/bin/start-agent-browser-host-allow <IP> <PORT>
#
# Why: The Agent-browser host broker (ADR 0010) spawns Chrome on the host
# loopback and bridges it into the container via host.docker.internal.
# On Docker Desktop (macOS, WSL2) the magic name resolves to a special
# host IP (typically 192.168.65.254). The container's default-deny OUTPUT
# chain (ADR 0001) doesn't allow that IP — it's not in 172.18.0.0/24 (the
# Docker bridge subnet that the existing ACCEPT rule covers) and it's not
# in the DNS-driven allowed-domains ipset. Packets hit the final REJECT,
# the in-container socat bridge sees EHOSTUNREACH ("No route to host"),
# and the CDP smoke test times out → rollback.
#
# This script opens a session-scoped exception: insert an ACCEPT for
# tcp/$PORT to $IP right before the final OUTPUT REJECT, mirroring the
# allow-for window pattern (start-allow-for-window.sh). Scoping to a
# single TCP port keeps the firewall hole as narrow as possible — only
# the CDP socket the broker actually needs is reachable, not arbitrary
# host services on the same magic IP. The broker pairs each start with a
# `stop-agent-browser-host-allow $IP $PORT` at session teardown
# (cmd_stop or any rollback path in cmd_start).
#
# Idempotent: if a matching rule already exists (e.g. a previous broker
# crash before cleanup), all duplicates are deleted first so the chain
# stays canonical.
#
# Arguments:
#   $1   IPv4 address to allow as an OUTPUT destination
#   $2   TCP destination port to allow (1-65535)
# =============================================================================

IP="${1:-}"
PORT="${2:-}"

# Reject anything that isn't four decimal octets in 0-255.
if ! [[ "$IP" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    echo "ERROR: IPv4 address required (got: '$IP')" >&2
    exit 2
fi
IFS='.' read -ra OCTETS <<< "$IP"
for octet in "${OCTETS[@]}"; do
    if (( octet < 0 || octet > 255 )); then
        echo "ERROR: IPv4 octet out of range (got: '$IP')" >&2
        exit 2
    fi
done

# TCP destination port: positive integer in 1..65535.
if ! [[ "$PORT" =~ ^[1-9][0-9]*$ ]] || (( PORT < 1 || PORT > 65535 )); then
    echo "ERROR: TCP port in 1..65535 required (got: '$PORT')" >&2
    exit 2
fi

# Pre-clean any stale matching rules. A crashed broker could have left
# duplicates; the loop drops them all so the new rule's position is the
# only one and stays canonical.
while iptables -D OUTPUT -p tcp -d "$IP" --dport "$PORT" -j ACCEPT 2>/dev/null; do
    :
done

# Locate the final catch-all REJECT in the OUTPUT chain. init-firewall.sh
# emits multiple REJECTs (Docker DNS guard, DNS pinning, catch-all); the
# catch-all is the only one shaped exactly `-A OUTPUT -j REJECT --reject-with...`
# with no qualifiers before `-j`. Same parsing approach as
# start-allow-for-window.sh — iptables-nft vs iptables-legacy differ in
# rendered columns, so `iptables -S` is the only stable shape.
reject_line=$(iptables -S OUTPUT 2>/dev/null \
    | awk '
        /^-A OUTPUT/ { n++ }
        /^-A OUTPUT -j REJECT --reject-with/ { last=n }
        END { if (last) print last }
    ')
if [ -z "$reject_line" ]; then
    echo "ERROR: could not locate final OUTPUT REJECT rule — firewall in unexpected state" >&2
    exit 1
fi

iptables -I OUTPUT "$reject_line" -p tcp -d "$IP" --dport "$PORT" -j ACCEPT
