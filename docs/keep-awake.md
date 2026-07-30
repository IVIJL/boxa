# Keep-awake

`boxa keep-awake` optionally runs a small host daemon that blocks idle sleep
only while one or more coding agents hold live leases. Enablement builds the
daemon from `keep-awake/` with the host's local Go toolchain, installs user
autostart, and creates a port-17777 Host connection trusted by every present
and future box.

```bash
boxa keep-awake enable
boxa keep-awake status
boxa keep-awake disable
```

The installer offers this elective once. A decline is remembered; plain
`boxa doctor` reports it without changing the choice. Enable it later with
`boxa keep-awake enable` or `boxa doctor --fix keep-awake`.

## Example activity hook

Clients should refresh a lease on each activity event. The daemon's default
TTL is 15 minutes, so a missed stop event cannot hold the machine awake
forever. On a clean stop, release the same agent/session lease immediately:

```bash
#!/usr/bin/env bash
set -euo pipefail

agent="${1:-claude}"
event="${2:-activity}"
session="${BOXA_PROJECT:-default}"

keep_awake_host() {
    # Inside a box, the global Host connection listens locally.
    if [ -f /etc/boxa/identity.json ]; then
        printf '127.0.0.1'
    # From WSL, use the Windows host's vEthernet/default-gateway address.
    elif grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
        ip route show default | awk 'NR == 1 { print $3; exit }'
    # Native Linux and macOS reach their host daemon directly.
    else
        printf '127.0.0.1'
    fi
}

base="http://$(keep_awake_host):17777"
case "$event" in
    start|activity)
        curl -fsS --max-time 2 \
            "$base/v1/busy/$agent?ttl=900&session=$session" >/dev/null
        ;;
    stop)
        curl -fsS --max-time 2 \
            "$base/v1/idle/$agent?session=$session" >/dev/null
        ;;
esac
```

Resolution order for any client is: native Linux/macOS → `localhost`; WSL →
the Windows vEthernet/default-gateway IP; boxa Container → `localhost` on the
Host connection's local port (17777 by default). `GET /v1/status` returns the
active holders, remaining TTLs, inhibitor state, and daemon version.
