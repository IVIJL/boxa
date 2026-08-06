#!/bin/bash
set -euo pipefail

# =============================================================================
# Start rootless Docker daemon (runs as node user, no privileges needed)
# =============================================================================

# Ensure XDG_RUNTIME_DIR exists (may be tmpfs, gets wiped on restart)
mkdir -p "$XDG_RUNTIME_DIR"

SOCKET="$XDG_RUNTIME_DIR/docker.sock"

# The socket remains node-owned and owner-only. boxa-bridge is exclusively the
# broker-control bridge; sharing the Docker socket through it would let every
# service-isolated process bypass the constrained Docker adapter by hardcoding
# this path.
secure_socket_for_node() {
    chgrp node "$SOCKET" && chmod 0600 "$SOCKET"
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

# Base patch pins DNS. On hosts where the rootless daemon's auto-selected
# driver is broken (macOS/LinuxKit → fuse-overlayfs, runc EINVAL), docker-run.sh
# passes BOXA_DIND_STORAGE_DRIVER (typically vfs) so we also pin storage-driver
# here. Built via jq --arg so the value is JSON-escaped, never interpolated
# into the filter string. The `storage-driver` key is added when the env var
# is set and removed when it is not, so a native-Linux run (or a run after the
# override was dropped) keeps the daemon's fast auto-selection.
if [ -n "${BOXA_DIND_STORAGE_DRIVER:-}" ]; then
    # $drv is a jq variable bound via --arg below (JSON-escaped by jq), not a
    # shell variable — single quotes are intentional so the shell leaves it be.
    # shellcheck disable=SC2016
    jq_filter='. + {"dns": ["10.0.2.2"], "storage-driver": $drv}'
    jq_args=(--arg drv "$BOXA_DIND_STORAGE_DRIVER")
    echo "Pinning inner Docker storage-driver to '${BOXA_DIND_STORAGE_DRIVER}'."
else
    # Also DROP any storage-driver pinned by a previous run: daemon.json
    # persists in the container image/volume, so without the del() a
    # one-off override would stay sticky forever and keep a native-Linux
    # daemon off its fast auto-selected driver.
    jq_filter='del(."storage-driver") + {"dns": ["10.0.2.2"]}'
    jq_args=()
fi
if [ -f "$DAEMON_JSON" ]; then
    tmp=$(mktemp)
    jq "${jq_args[@]}" "$jq_filter" "$DAEMON_JSON" > "$tmp" && mv "$tmp" "$DAEMON_JSON"
else
    jq -n "${jq_args[@]}" "$jq_filter" > "$DAEMON_JSON"
fi

# Skip if already running
if [ -S "$SOCKET" ] && docker info >/dev/null 2>&1; then
    echo "Rootless Docker is already running."
    secure_socket_for_node
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
        secure_socket_for_node
        exit 0
    fi
    sleep 1
done

echo "ERROR: Rootless Docker failed to start within ${TIMEOUT}s."
echo "Check /tmp/dockerd-rootless.log for details."
exit 1
