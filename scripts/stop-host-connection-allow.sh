#!/bin/bash
set -euo pipefail

# Remove the durable, single-IP/single-port OUTPUT Host connection slot.
# This root-owned image script is invoked only by the host-side boxa CLI.

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

while iptables -D OUTPUT -p tcp -d "$IP" --dport "$PORT" -j ACCEPT 2>/dev/null; do
    :
done
