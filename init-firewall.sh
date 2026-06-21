#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# Boxa Firewall - Based on Claude Code default-deny with extensions
# =============================================================================

# shellcheck source=lib/allowlist.sh
source /usr/local/share/boxa/lib/allowlist.sh

# Closeout for an allow-for window that survived a container restart
# (ADR 0009 Phase 5). Runs BEFORE flushing — the helper only reads the
# sentinel and the persisted dnsmasq queries log, never touches the
# firewall (init-firewall is about to wipe it anyway). Best-effort: a
# missing sentinel is the common case and exits silently; any internal
# failure inside the helper must not block firewall setup, hence the
# `|| true` belt-and-braces.
if [ -x /usr/local/bin/closeout-allow-for-on-restart ]; then
    /usr/local/bin/closeout-allow-for-on-restart || true
fi

# 1. Extract Docker DNS info BEFORE any flushing
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

# Flush existing rules and delete existing ipsets
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy "$IPSET_NAME" 2>/dev/null || true

# 2. Selectively restore ONLY internal Docker DNS resolution
if [ -n "$DOCKER_DNS_RULES" ]; then
    echo "Restoring Docker DNS rules..."
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
else
    echo "No Docker DNS rules to restore"
fi

# Pin outbound DNS to the in-container resolver (127.0.0.1 = dnsmasq).
# External UDP/TCP 53 and DoT (TCP 853) are rejected so every name
# resolution flows through our audited resolver — precondition for the
# allow-for harvest pool (ADR 0009) and a general hardening win.
iptables -A OUTPUT -p udp --dport 53 -d 127.0.0.1 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -d 127.0.0.1 -j ACCEPT

# Allow the Docker embedded resolver's OWN upstream forward. On native Linux
# with a non-loopback Docker daemon DNS (daemon.json "dns", e.g. 172.17.0.1),
# the embedded resolver at 127.0.0.11 forwards external queries FROM this
# container's netns to that upstream, so the packet traverses this OUTPUT
# chain and the catch-all --dport 53 REJECT below would kill every lookup. A
# loopback daemon DNS (Ubuntu systemd-resolved 127.0.0.53, Docker Desktop) is
# proxied host-side and never reaches here, so the list is empty and this
# block is skipped. The IPs are detected host-side (docker-run.sh) — the
# container only ever sees 127.0.0.11 in resolv.conf, never the real
# upstream(s). They arrive via a bind-mounted file (not an env var) so a
# `docker start` restart re-reads the current value; the list is space-
# separated because daemon.json may declare several DNS servers and Docker
# falls back to later ones, so each must be allowed. Narrow dst-IP allow: the
# allowlist's connection-layer ipset enforcement (below) is untouched, so a
# direct query here still cannot connect anywhere new. See docs/adr/0015.
BOXA_DNS_UPSTREAM=""
if [ -f "$DNS_UPSTREAM_CONTAINER_FILE" ]; then
    BOXA_DNS_UPSTREAM=$(cat "$DNS_UPSTREAM_CONTAINER_FILE")
fi
if [ -n "${BOXA_DNS_UPSTREAM:-}" ]; then
    # Split on spaces explicitly: the script-wide IFS=$'\n\t' (line 3) does NOT
    # include a space, so a bare `for upstream in $BOXA_DNS_UPSTREAM` would
    # treat the whole list as one token and fail the IPv4 check below.
    IFS=' ' read -ra _dns_upstreams <<< "$BOXA_DNS_UPSTREAM"
    for upstream in "${_dns_upstreams[@]}"; do
        if [[ "$upstream" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "Allowing Docker DNS upstream forward to ${upstream}"
            iptables -A OUTPUT -p udp --dport 53 -d "$upstream" -j ACCEPT
            iptables -A OUTPUT -p tcp --dport 53 -d "$upstream" -j ACCEPT
        else
            echo "WARNING: ignoring malformed BOXA_DNS_UPSTREAM entry '${upstream}' (expected IPv4)"
        fi
    done
fi

iptables -A OUTPUT -p udp --dport 53 -j REJECT --reject-with icmp-admin-prohibited
iptables -A OUTPUT -p tcp --dport 53 -j REJECT --reject-with icmp-admin-prohibited
iptables -A OUTPUT -p tcp --dport 853 -j REJECT --reject-with icmp-admin-prohibited
iptables -A INPUT -p udp --sport 53 -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Create ipset with CIDR support
ipset create "$IPSET_NAME" hash:net

# Fetch GitHub meta information and aggregate + add their IP ranges.
# Non-fatal: the GitHub IPs are only needed for git/gh operations against
# github.com from inside the container — the container itself boots fine
# without them. Failure here (anonymous rate limit on api.github.com,
# network issue, malformed response) prints a warning and skips the
# ipset prefill so the container can still start. Run
# `sudo boxa-firewall-reload` once GitHub is reachable again to
# populate the ipset retroactively.
echo "Fetching GitHub IP ranges..."
GITHUB_IPS_LOADED=0
gh_ranges=$(curl -s --max-time 10 https://api.github.com/meta || true)
if [ -z "$gh_ranges" ]; then
    echo "WARNING: Failed to fetch GitHub IP ranges — git/gh against github.com will fail until firewall reload"
elif ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null 2>&1; then
    echo "WARNING: GitHub API response missing required fields (likely anonymous rate limit on shared public IP) — git/gh against github.com will fail until firewall reload"
else
    echo "Processing GitHub IPs..."
    while read -r cidr; do
        if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
            echo "WARNING: Invalid CIDR range from GitHub meta: $cidr (skipped)"
            continue
        fi
        echo "Adding GitHub range $cidr"
        ipset add "$IPSET_NAME" "$cidr"
    done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | aggregate -q)
    GITHUB_IPS_LOADED=1
fi

# =============================================================================
# Allowed domains — all resolved dynamically via dnsmasq
# =============================================================================
# Domain rules come from the bind-mounted allowlist file. dnsmasq's ipset=
# directive adds resolved IPs to the ipset at DNS lookup time. See
# docs/adr/0001-dnsmasq-dynamic-allowlist.md for the rationale.

ALLOWLIST_DOMAIN_COUNT=0
if [ -f "$ALLOWLIST_CONTAINER_FILE" ]; then
    ALLOWLIST_DOMAIN_COUNT=$(allowlist::read "$ALLOWLIST_CONTAINER_FILE" | wc -l)
fi

if [ "$ALLOWLIST_DOMAIN_COUNT" -eq 0 ]; then
    echo "WARNING: No allowed domains found in $ALLOWLIST_CONTAINER_FILE"
    echo "Firewall will block all outbound traffic except GitHub."
fi

# Get host IP from default route
HOST_IP=$(ip route | grep default | cut -d" " -f3)
if [ -z "$HOST_IP" ]; then
    echo "ERROR: Failed to detect host IP"
    exit 1
fi

HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/24/")
echo "Host network detected as: $HOST_NETWORK"

# Set up remaining iptables rules
iptables -A INPUT -s "$HOST_NETWORK" -j ACCEPT
iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT

# Set default policies to DROP
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# Allow established connections
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow only outbound traffic to allowed domains
iptables -A OUTPUT -m set --match-set "$IPSET_NAME" dst -j ACCEPT

# Reject all other outbound traffic for immediate feedback
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

# =============================================================================
# dnsmasq — dynamic DNS-to-ipset resolution for all allowed domains
# =============================================================================
echo "Configuring dnsmasq for ${ALLOWLIST_DOMAIN_COUNT} domain(s)..."

# Save Docker's upstream DNS before overwriting resolv.conf
UPSTREAM_DNS=$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf)

# Generate dnsmasq static config (no domain rules — those go to boxa-runtime.conf)
mkdir -p /etc/dnsmasq.d
cat > /etc/dnsmasq.d/boxa-firewall.conf <<DNSCONF
# Boxa firewall — static dnsmasq config
bind-interfaces
listen-address=127.0.0.1
port=53
# Pin dnsmasq to the dnsmasq user explicitly. The DNS-bypass guard below
# (allow 127.0.0.11 only for --uid-owner dnsmasq) depends on this — if
# dnsmasq fell back to nobody, its own upstream queries would be rejected.
# No group= line on purpose: Debian's dnsmasq postinst creates user
# dnsmasq with primary group nogroup, not a same-named group, so an
# explicit group=dnsmasq would make dnsmasq fail to start. The iptables
# rule below matches on UID anyway via --uid-owner, so GID is irrelevant.
user=dnsmasq
no-resolv
server=${UPSTREAM_DNS}
log-queries
log-facility=/var/log/dnsmasq-queries.log
DNSCONF

# Generate domain ipset rules in runtime config (regenerated by boxa allow/deny)
allowlist::render_dnsmasq "$ALLOWLIST_CONTAINER_FILE" "$DNSMASQ_RUNTIME_FILE"

# Start dnsmasq
dnsmasq --conf-dir=/etc/dnsmasq.d --keep-in-foreground &
DNSMASQ_PID=$!
sleep 0.5

if kill -0 "$DNSMASQ_PID" 2>/dev/null; then
    echo "dnsmasq started (PID $DNSMASQ_PID)"
    # Redirect container DNS through dnsmasq
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
else
    echo "ERROR: dnsmasq failed to start"
    wait "$DNSMASQ_PID" || true
    exit 1
fi

# Close the Docker embedded DNS bypass at 127.0.0.11. The Docker DNS NAT
# rules restored above DNAT 127.0.0.11:53 to a high port before filter
# OUTPUT runs, so the `--dport 53` REJECTs miss the packet and
# `-o lo -j ACCEPT` would then let it through. Block the destination —
# except for dnsmasq itself, which forwards to ${UPSTREAM_DNS} captured
# from the original resolv.conf (= 127.0.0.11 on user-defined Docker
# networks). Without the dnsmasq exception, every allowed-domain
# resolution would fail. Rules inserted in reverse order so the
# resulting OUTPUT chain has the dnsmasq-allow *before* the
# everyone-reject. The whole block must happen after the GitHub IP
# fetch above, which still needs Docker DNS unfiltered.
iptables -I OUTPUT 1 -d 127.0.0.11 -j REJECT --reject-with icmp-admin-prohibited
iptables -I OUTPUT 1 -d 127.0.0.11 -m owner --uid-owner dnsmasq -j ACCEPT

# Sanity-probe the upstream resolver path now that lockdown is complete.
# dnsmasq forwards every query to ${UPSTREAM_DNS} (127.0.0.11 → Docker
# embedded → daemon upstream). If that chain is dead, the firewall still
# reports success below: the positive reachability checks are GitHub-gated
# (skipped when the meta fetch failed) and the negative ones pass precisely
# *because* nothing resolves — a silent failure that masquerades as a clean
# boot (the original native-Linux / non-loopback-daemon-DNS symptom). Make it
# loud. See docs/adr/0015.
if [ -z "$(dig +short +time=3 +tries=1 @127.0.0.1 github.com 2>/dev/null)" ]; then
    echo "WARNING: upstream DNS is not answering — name resolution will fail inside this container."
    if [ -z "${BOXA_DNS_UPSTREAM:-}" ]; then
        echo "         If this host sets a non-loopback Docker daemon DNS (daemon.json \"dns\"),"
        echo "         docker-run.sh did not detect it (BOXA_DNS_UPSTREAM is empty). See docs/adr/0015."
    else
        echo "         The detected upstream ${BOXA_DNS_UPSTREAM} did not resolve. See docs/adr/0015."
    fi
fi

echo "Firewall configuration complete"
echo "Verifying firewall rules..."
if curl --connect-timeout 5 https://www.google.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - was able to reach https://www.google.com"
    exit 1
else
    echo "Firewall verification passed - unable to reach https://www.google.com as expected"
fi

# Only assert GitHub reachability if the meta fetch above actually
# populated the ipset. When the fetch was skipped (rate limit / network),
# api.github.com is *expected* to be blocked by the catch-all REJECT, so
# the positive assertion would always fail.
if [ "$GITHUB_IPS_LOADED" -eq 1 ]; then
    if ! curl --connect-timeout 5 https://api.github.com/zen >/dev/null 2>&1; then
        echo "ERROR: Firewall verification failed - unable to reach https://api.github.com"
        exit 1
    else
        echo "Firewall verification passed - able to reach https://api.github.com as expected"
    fi
else
    echo "Firewall verification skipped for GitHub - IPs not loaded (run sudo boxa-firewall-reload once GitHub is reachable)"
fi

# DNS pinning check — external resolvers must be unreachable so every
# query flows through the in-container dnsmasq (ADR 0009 invariant).
if dig +short +tries=1 +time=3 @8.8.8.8 google.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - external DNS @8.8.8.8 is reachable"
    exit 1
else
    echo "Firewall verification passed - external DNS @8.8.8.8 unreachable as expected"
fi

# Docker's embedded DNS at 127.0.0.11 must also be blocked, otherwise a
# process can bypass dnsmasq by querying it directly. Regression check
# for the explicit REJECT inserted right after dnsmasq starts.
if dig +short +tries=1 +time=3 @127.0.0.11 google.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - Docker embedded DNS @127.0.0.11 is reachable"
    exit 1
else
    echo "Firewall verification passed - Docker embedded DNS @127.0.0.11 unreachable as expected"
fi
