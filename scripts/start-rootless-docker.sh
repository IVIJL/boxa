#!/bin/bash
set -euo pipefail

# =============================================================================
# Start rootless Docker daemon (runs as node user, no privileges needed)
# =============================================================================

# Ensure XDG_RUNTIME_DIR exists (may be tmpfs, gets wiped on restart)
mkdir -p "$XDG_RUNTIME_DIR"

SOCKET="$XDG_RUNTIME_DIR/docker.sock"

# Share the rootless Docker socket with the `boxa-bridge` group (ADR 0014
# "Update 2026-05-31"). The daemon runs as `node` and creates the socket
# `node:node`, which `boxa-mcp` cannot reach. We are `node` here (this script
# runs in the node phase, after the entrypoint drop), so we own the socket and
# can re-group it WITHOUT root — honoring ADR 0003 (no setuid/NOPASSWD/persistent
# root). Group `boxa-bridge` (both `node` and `boxa-mcp` are members, see the
# Dockerfile) + `g+rw` lets a broker-spawned `docker`-launcher MCP server reach
# the daemon, without adding `boxa-mcp` to `node`'s group and without changing
# the socket's OWNER. Documented trade-off: this grants node-level Docker
# capability to such a server (ADR 0014). Idempotent: safe to re-run.
share_socket_with_bridge() {
    # Only when the bridge group exists (image built with ADR 0014 issue 19+).
    if getent group boxa-bridge >/dev/null 2>&1; then
        chgrp boxa-bridge "$SOCKET" && chmod g+rw "$SOCKET"
    fi
}

# Pin inner-container DNS to the slirp4netns gateway (10.0.2.2). Without
# this, inner DinD containers inherit Docker's fallback resolv.conf
# (nameserver 8.8.8.8), and the ADR 0009 DNS-pinning rule REJECTs every
# external DNS query — apt/curl in any FROM-image build silently fails
# with "Temporary failure resolving". The slirp gateway loopback-maps
# 10.0.2.2 in the inner netns to 127.0.0.1 in the boxa netns, where
# dnsmasq listens, so every inner-container DNS query still flows
# through the audited resolver and populates the allowlist ipset.
DAEMON_JSON="$HOME/.config/docker/daemon.json"
mkdir -p "$(dirname "$DAEMON_JSON")"
if [ -f "$DAEMON_JSON" ]; then
    tmp=$(mktemp)
    jq '. + {"dns": ["10.0.2.2"]}' "$DAEMON_JSON" > "$tmp" && mv "$tmp" "$DAEMON_JSON"
else
    printf '%s\n' '{"dns": ["10.0.2.2"]}' > "$DAEMON_JSON"
fi

# Skip if already running
if [ -S "$SOCKET" ] && docker info >/dev/null 2>&1; then
    echo "Rootless Docker is already running."
    share_socket_with_bridge
    exit 0
fi

echo "Starting rootless Docker daemon..."
# Inner containers need to reach services listening on the outer boxa
# loopback via 10.0.2.2. This still does not expose the host Docker socket or
# host ports; it only opens the parent namespace seen by RootlessKit.
: "${DOCKERD_ROOTLESS_ROOTLESSKIT_DISABLE_HOST_LOOPBACK:=false}"
export DOCKERD_ROOTLESS_ROOTLESSKIT_DISABLE_HOST_LOOPBACK
dockerd-rootless.sh >/tmp/dockerd-rootless.log 2>&1 &

# Wait for the socket to appear
TIMEOUT=30
for i in $(seq 1 "$TIMEOUT"); do
    if [ -S "$SOCKET" ]; then
        echo "Rootless Docker started successfully (${i}s)."
        share_socket_with_bridge
        exit 0
    fi
    sleep 1
done

echo "ERROR: Rootless Docker failed to start within ${TIMEOUT}s."
echo "Check /tmp/dockerd-rootless.log for details."
exit 1
