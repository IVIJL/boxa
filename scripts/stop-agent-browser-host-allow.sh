#!/bin/bash
set -euo pipefail

# =============================================================================
# stop-agent-browser-host-allow — close the Agent-browser session firewall slot
# =============================================================================
# Counterpart of start-agent-browser-host-allow. Runs inside a boxa
# container as root, invoked from the host via
#   docker exec -u root <container> /usr/local/bin/stop-agent-browser-host-allow <IP> <PORT>
#
# Idempotent: removes every matching OUTPUT tcp/dport ACCEPT rule for
# $IP+$PORT (defensive against duplicates left by an earlier crashed
# broker invocation). If no matching rule exists this is a silent no-op
# success — the caller wanted the slot closed and it is.
#
# Arguments:
#   $1   IPv4 address whose OUTPUT ACCEPT rule should be removed
#   $2   TCP destination port (1-65535) whose OUTPUT ACCEPT rule should be removed
# =============================================================================

IP="${1:-}"
PORT="${2:-}"

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

if ! [[ "$PORT" =~ ^[1-9][0-9]*$ ]] || (( PORT < 1 || PORT > 65535 )); then
    echo "ERROR: TCP port in 1..65535 required (got: '$PORT')" >&2
    exit 2
fi

# `iptables -D` removes one matching rule per call; loop until the chain has
# no matches left. Errors (no rule) are expected and silent.
while iptables -D OUTPUT -p tcp -d "$IP" --dport "$PORT" -j ACCEPT 2>/dev/null; do
    :
done
