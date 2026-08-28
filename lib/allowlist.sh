# shellcheck shell=bash
# =============================================================================
# Boxa firewall allowlist — single source of truth
# =============================================================================
# Sourced by:
#   - docker-run.sh (host)         to read/edit the shared allowlist
#   - init-firewall.sh (container) to render dnsmasq runtime config at startup
#   - boxa-firewall-reload (container) to regenerate dnsmasq config on allow/deny
#
# Path constants differ between host and container; pick the one that exists.
# Functions never assume which side they run on — paths are passed as args.
#
# Wildcard semantic: `foo.com` and `*.foo.com` are equivalent and both
# match the domain plus all subdomains. See docs/adr/0001-dnsmasq-dynamic-allowlist.md.
# =============================================================================

# --- Constants ---------------------------------------------------------------
# All constants are consumed by sourcing scripts; shellcheck can't see that.
# shellcheck disable=SC2034

# Shared-config manifest. Only these files may live in the directory mounted
# into Containers (ADR 0036).
SHARED_CONFIG_FILES=(allowed-domains.conf dns-upstream.conf)

# Host (set by docker-run.sh callers)
ALLOWLIST_HOST_DIR="${HOME:-/root}/.config/boxa"
SHARED_CONFIG_HOST_DIR="$ALLOWLIST_HOST_DIR/shared"
ALLOWLIST_HOST_FILE="$SHARED_CONFIG_HOST_DIR/allowed-domains.conf"

# Container (set by init-firewall.sh and boxa-firewall-reload callers)
SHARED_CONFIG_CONTAINER_DIR="/etc/boxa-shared/config"
ALLOWLIST_CONTAINER_FILE="$SHARED_CONFIG_CONTAINER_DIR/allowed-domains.conf"
DNSMASQ_RUNTIME_FILE="/etc/dnsmasq.d/boxa-runtime.conf"

# Docker DNS upstream allow-list (ADR 0015). Host detects the embedded
# resolver's non-loopback upstream(s) and writes them here; the container
# reads them at firewall init to allow that one forward. A file in the mounted
# shared-config directory (not a docker -e env var) so it is re-read on
# `docker start` restarts, not frozen at create time.
DNS_UPSTREAM_HOST_FILE="$SHARED_CONFIG_HOST_DIR/dns-upstream.conf"
DNS_UPSTREAM_CONTAINER_FILE="$SHARED_CONFIG_CONTAINER_DIR/dns-upstream.conf"

# Shared
IPSET_NAME="allowed-domains"

# --- Functions ---------------------------------------------------------------

# Read entries from an allowlist file. Skips blanks and comments.
# Preserves the original form (with or without `*.` prefix).
#
# Usage: allowlist::read <file>
# Output: one entry per line on stdout
allowlist::read() {
    local file="$1"
    [ -f "$file" ] || return 0
    sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$file" \
        | grep -v '^$' || true
}

# Append a domain to the allowlist file, deduplicated.
# Returns 0 if added, 1 if already present (caller can echo accordingly).
#
# Usage: allowlist::add <file> <domain>
allowlist::add() {
    local file="$1" domain="$2"
    mkdir -p "$(dirname "$file")"
    touch "$file"
    if grep -qxF "$domain" "$file" 2>/dev/null; then
        return 1
    fi
    echo "$domain" >> "$file"
}

# Remove a domain (exact match) from the allowlist file.
# Returns 0 if removed, 1 if not present.
#
# Rewrites the file IN PLACE (preserving its inode) rather than via a
# temp-file `mv`. New Containers mount the parent directory and do not depend
# on the member's inode, but Containers still running across the ADR 0036
# transition retain the legacy single-file mount until restarted. Keeping the
# rewrite in place protects that finite transition window. `allowlist::add`
# already appends with `>>` and is safe for both layouts.
#
# Usage: allowlist::remove <file> <domain>
allowlist::remove() {
    local file="$1" domain="$2"
    [ -f "$file" ] || return 1
    if ! grep -qxF -- "$domain" "$file" 2>/dev/null; then
        return 1
    fi
    local remaining
    remaining=$(grep -vxF -- "$domain" "$file" 2>/dev/null) || true
    if [ -n "$remaining" ]; then
        printf '%s\n' "$remaining" > "$file"
    else
        : > "$file"
    fi
}

# Render dnsmasq runtime config from the allowlist.
# Strips `*.` prefix (dnsmasq matches the domain + all subdomains by design).
#
# Usage: allowlist::render_dnsmasq <input_file> <output_file>
allowlist::render_dnsmasq() {
    local input="$1" output="$2"
    : > "$output"
    while IFS= read -r domain; do
        # Strip leading "*." — dnsmasq's ipset= already matches all subdomains.
        domain="${domain#\*.}"
        echo "ipset=/${domain}/${IPSET_NAME}" >> "$output"
    done < <(allowlist::read "$input")
}

# Seed allowlist file from defaults if missing; merge any missing default
# entries into an existing file (idempotent).
#
# Existing user-added entries and comments are preserved. New defaults from
# the seed file are appended once with a "# auto-merged from defaults" marker.
#
# Usage: allowlist::ensure_seeded <target_file> <defaults_file>
allowlist::ensure_seeded() {
    local target="$1" defaults="$2"
    mkdir -p "$(dirname "$target")"

    # First-run: copy defaults verbatim (preserves header comments).
    if [ ! -f "$target" ]; then
        cp "$defaults" "$target"
        return 0
    fi

    # Merge: append defaults that aren't already present.
    local missing=()
    while IFS= read -r entry; do
        grep -qxF "$entry" "$target" 2>/dev/null || missing+=("$entry")
    done < <(allowlist::read "$defaults")

    if [ ${#missing[@]} -gt 0 ]; then
        {
            echo ""
            echo "# auto-merged from defaults ($(date +%Y-%m-%d))"
            printf '%s\n' "${missing[@]}"
        } >> "$target"
    fi
}
