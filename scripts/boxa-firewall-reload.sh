#!/bin/bash
set -euo pipefail

# =============================================================================
# boxa-firewall-reload — regenerate dnsmasq runtime config and restart it
# =============================================================================
# Runs inside a boxa container as root. Called by docker-run.sh's
# `boxa allow` and `boxa deny` via `docker exec`.
#
# Usage:
#   boxa-firewall-reload                      # plain reload
#   boxa-firewall-reload allow <domain>       # reload + warm dnsmasq cache for <domain>
#   boxa-firewall-reload deny  "<dom1> <dom2>" # reload + drop denied IPs from ipset
# =============================================================================

# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=lib/allowlist.sh
source /usr/local/share/boxa/lib/allowlist.sh

ACTION="${1:-}"
DOMAINS="${2:-}"

_render_dev_url_dns() {
    local config_file="$1" traefik_ip

    traefik_ip=$(runuser -u dnsmasq -- \
        dig +short +time=2 +tries=1 @127.0.0.11 boxa_traefik A 2>/dev/null \
        | awk 'NR == 1 { print $1 }' || true)
    sed -i -e '\|^address=/test/|d' \
        -e '\|^address=/127\.0\.0\.1\.sslip\.io/|d' "$config_file"
    if [[ "$traefik_ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        printf 'address=/test/%s\naddress=/127.0.0.1.sslip.io/%s\n' \
            "$traefik_ip" "$traefik_ip" >> "$config_file"
    fi
}

# 1. Refresh dev URL DNS through the permanent dnsmasq-owner exception for
# Docker embedded DNS, then regenerate runtime config from the allowlist file.
_render_dev_url_dns /etc/dnsmasq.d/boxa-firewall.conf
allowlist::render_dnsmasq "$ALLOWLIST_CONTAINER_FILE" "$DNSMASQ_RUNTIME_FILE"

# 2. Restart dnsmasq. SIGTERM first; escalate to SIGKILL if it lingers.
if pgrep -x dnsmasq >/dev/null 2>&1; then
    pkill -TERM -x dnsmasq 2>/dev/null || true
    for _ in 1 2 3 4 5; do
        pgrep -x dnsmasq >/dev/null 2>&1 || break
        sleep 0.1
    done
    if pgrep -x dnsmasq >/dev/null 2>&1; then
        pkill -KILL -x dnsmasq 2>/dev/null || true
        sleep 0.1
    fi
fi
rm -f /run/dnsmasq/dnsmasq.pid /var/run/dnsmasq/dnsmasq.pid 2>/dev/null || true

if ! dnsmasq --conf-dir=/etc/dnsmasq.d; then
    echo "ERROR: dnsmasq failed to start" >&2
    exit 1
fi

# Verify it's actually running (dnsmasq forks; non-zero exit above isn't enough).
sleep 0.3
if ! pgrep -x dnsmasq >/dev/null 2>&1; then
    echo "ERROR: dnsmasq not running after start" >&2
    exit 1
fi

# 3. Domain-specific side effects.
case "$ACTION" in
    allow)
        # Warm the ipset by resolving the new domain through dnsmasq.
        if [ -n "$DOMAINS" ]; then
            nslookup "${DOMAINS#\*.}" 127.0.0.1 >/dev/null 2>&1 || true
        fi
        ;;
    deny)
        # Drop currently-resolved IPs of denied domains from the ipset.
        # New connections to them will be blocked; established ones drain naturally.
        for d in $DOMAINS; do
            d="${d#\*.}"
            nslookup "$d" 127.0.0.1 2>/dev/null \
                | grep -oP "Address: \K[0-9.]+" \
                | while read -r ip; do
                    ipset del "$IPSET_NAME" "$ip" 2>/dev/null || true
                done
        done
        ;;
    "")
        : # plain reload
        ;;
    *)
        echo "ERROR: unknown action '$ACTION' (expected: allow|deny|empty)" >&2
        exit 2
        ;;
esac
