# shellcheck shell=bash
# =============================================================================
# Boxa firewall allowlist — single source of truth
# =============================================================================
# Sourced by:
#   - docker-run.sh (host)         to read/edit ~/.config/boxa/allowed-domains.conf
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

# Host (set by docker-run.sh callers)
ALLOWLIST_HOST_FILE="${HOME:-/root}/.config/boxa/allowed-domains.conf"
ALLOWLIST_HOST_DIR="${HOME:-/root}/.config/boxa"

# Container (set by init-firewall.sh and boxa-firewall-reload callers)
ALLOWLIST_CONTAINER_FILE="/etc/boxa-shared/allowed-domains.conf"
DNSMASQ_RUNTIME_FILE="/etc/dnsmasq.d/boxa-runtime.conf"

# Docker DNS upstream allow-list (ADR 0015). Host detects the embedded
# resolver's non-loopback upstream(s) and writes them here; the container
# reads them at firewall init to allow that one forward. A bind-mounted file
# (not a docker -e env var) so it is re-read on `docker start` restarts, not
# frozen at create time.
DNS_UPSTREAM_HOST_FILE="${HOME:-/root}/.config/boxa/dns-upstream.conf"
DNS_UPSTREAM_CONTAINER_FILE="/etc/boxa-shared/dns-upstream.conf"

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
# Usage: allowlist::remove <file> <domain>
allowlist::remove() {
    local file="$1" domain="$2"
    [ -f "$file" ] || return 1
    if ! grep -qxF "$domain" "$file" 2>/dev/null; then
        return 1
    fi
    local tmp="${file}.tmp.$$"
    grep -vxF "$domain" "$file" > "$tmp" || true
    mv "$tmp" "$file"
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
