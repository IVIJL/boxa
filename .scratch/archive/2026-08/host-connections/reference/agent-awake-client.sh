#!/bin/sh
# Signal the Agent Awake service on the Windows host (busy/idle keep-awake).
# Works from the WSL host and from boxa containers; silent no-op when unreachable.
action="${1:-busy}"
agent="${2:-claude}"

if [ -d /mnt/c ]; then
    # WSL host: the default gateway is the Windows vEthernet (WSL) address.
    host=$(ip route show default 2>/dev/null | awk '{print $3; exit}')
else
    # Container: the boxa-agent-awake-relay sidecar (socat on the devproxy
    # network, static IP) forwards to host.docker.internal:17777. The bridge
    # subnet is already ACCEPTed by the boxa egress firewall, so no allowlist
    # entry is needed.
    host=172.18.0.250
fi

if [ -n "$host" ]; then
    curl -fsS -4 -m 1 "http://$host:17777/$action/$agent" >/dev/null 2>&1 || true
fi
exit 0
