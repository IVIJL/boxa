# shellcheck shell=bash
# =============================================================================
# Boxa project naming — single source of truth for derived names
# =============================================================================
# Sourced by docker-run.sh (host). Owns the format of:
#   - container name        boxa-<project>
#   - hostname              <project>
#   - per-project volumes   boxa-<project>-{history,docker}
#   - workspace alias       /workspace/<project>
#   - traefik route hosts   [<port>.]<project>.<active-domain>     (display)
#                           [<port>.]<project>.test                (local)
#                           [<port>.]<project>.127.0.0.1.<ext>     (external)
#
# All derivations go through `boxa::sanitize` so forward construction matches
# the reverse derivation patterns (`${container#boxa-}`, regex on volume
# names). See docs/adr/0005-project-naming-from-sanitized-basename.md.
#
# DNS surface is dual-mode (local `.test` + external wildcard provider) per
# ADR 0007. `route_hosts` yields both forms for Traefik dual-`Host()` rules;
# `route_host_display` yields a single user-facing form based on the active
# mode in `~/.config/boxa/dns.conf` (overridable via `BOXA_DNS_CONF`).
# =============================================================================

# --- Constants ---------------------------------------------------------------
# Consumed by sourcing scripts; shellcheck can't see that.
# shellcheck disable=SC2034

BOXA_PROJECT_VOLUME_SUFFIXES=(history docker)

# Local TLD. RFC 2606 reserved for testing; chosen for browser/CLI parity
# (no baked-in browser fast-path like *.localhost has). Constant — not
# user-configurable. See ADR 0007 § "TLD: `.test` (not `.localhost`)".
BOXA_LOCAL_TLD="test"

# --- DNS config (lazy-loaded from dns.conf) ----------------------------------

# Internal cache. Read via boxa::route_domain / boxa::external_provider /
# boxa::dns_preferred; reset via boxa::reset_dns_cache (used by tests and by
# dns-install after rewriting dns.conf within the same process).
_BOXA_DNS_CONF_LOADED=
_BOXA_ACTIVE_DOMAIN=
_BOXA_EXTERNAL_PROVIDER=
_BOXA_DNS_PREFERRED=

boxa::reset_dns_cache() {
    _BOXA_DNS_CONF_LOADED=
    _BOXA_ACTIVE_DOMAIN=
    _BOXA_EXTERNAL_PROVIDER=
    _BOXA_DNS_PREFERRED=
}

# Parse ~/.config/boxa/dns.conf (or $BOXA_DNS_CONF) into the cache. The
# file format is `key=value` per line with `#` comments. We intentionally do
# *not* `source` it — strict parse, fixed key allow-list, no ambient pollution
# if a stray line slips in.
_boxa::load_dns_conf() {
    [ -n "$_BOXA_DNS_CONF_LOADED" ] && return 0
    _BOXA_DNS_CONF_LOADED=1
    _BOXA_ACTIVE_DOMAIN="$BOXA_LOCAL_TLD"
    _BOXA_EXTERNAL_PROVIDER="sslip.io"
    # `preferred` defaults to empty (not `local`): an absent dns.conf means
    # the user has not run dns-install yet, which is NOT the same as a
    # degraded local install awaiting retry. Self-heal keys off the explicit
    # `preferred=local` a real install writes.
    _BOXA_DNS_PREFERRED=""
    local conf="${BOXA_DNS_CONF:-$HOME/.config/boxa/dns.conf}"
    [ -f "$conf" ] || return 0
    local line key value
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ -z "$line" ] && continue
        key="${line%%=*}"
        value="${line#*=}"
        [ "$key" = "$line" ] && continue
        key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"
        case "$key" in
            active_domain)     [ -n "$value" ] && _BOXA_ACTIVE_DOMAIN="$value" ;;
            external_provider) [ -n "$value" ] && _BOXA_EXTERNAL_PROVIDER="$value" ;;
            preferred)         [ -n "$value" ] && _BOXA_DNS_PREFERRED="$value" ;;
        esac
    done < "$conf"
}

# --- Public API --------------------------------------------------------------

# Sanitize an arbitrary string into a name safe for docker objects AND for
# DNS labels (RFC 1034/1035 LDH): replace runs of non-[A-Za-z0-9-] with a
# single dash, then trim leading and trailing dashes.
#
# `_` and `.` are deliberately excluded — both are valid in docker container
# and volume names but not in DNS labels, and the same project name flows
# into the Traefik route host. Keeping the allowlist strict at LDH lets
# every derived name stay valid simultaneously.
#
# Usage: boxa::sanitize <s>
boxa::sanitize() {
    echo "$1" | tr -cs 'a-zA-Z0-9-' '-' | sed 's/^-//;s/-$//'
}

# Compute a `boxa-<project>-<suffix>` volume name.
#
# Usage: boxa::volume_name <project> <suffix>
boxa::volume_name() {
    printf 'boxa-%s-%s' "$1" "$2"
}

# Return the active route domain string (e.g. `test` for local mode,
# `127.0.0.1.sslip.io` for external mode). Defaults to `test` if dns.conf
# is absent or the field is unset.
boxa::route_domain() {
    _boxa::load_dns_conf
    printf '%s' "$_BOXA_ACTIVE_DOMAIN"
}

# Return the configured external wildcard DNS provider (e.g. `sslip.io`).
# Default `sslip.io`. Configurable so we are never locked to one vendor — see
# ADR 0007 § "External provider".
boxa::external_provider() {
    _boxa::load_dns_conf
    printf '%s' "$_BOXA_EXTERNAL_PROVIDER"
}

# Return the persisted mode *preference* (`local` | `external` | `auto` | "").
# This is the user's intent, which can diverge from `active_domain` (what URLs
# advertise) in the degraded state: `preferred=local` + an external
# `active_domain` means "local was wanted but the host resolver setup failed —
# advertise the working sslip.io URLs for now and retry the resolver later".
# Self-heal (`_boxa::resolver_drop_in_missing`) reads this to know whether to
# re-attempt the resolver drop-in. Empty when dns.conf is absent.
boxa::dns_preferred() {
    _boxa::load_dns_conf
    printf '%s' "$_BOXA_DNS_PREFERRED"
}

# Yield every Traefik route hostname for a project, one per line. Always
# emits both the local (`.test`) and the external (`.127.0.0.1.<provider>`)
# form so the generated dual-`Host()` rule keeps working across mode switches
# without regenerating dynamic configs (ADR 0007 § "Both URLs work
# simultaneously in Traefik").
#
# Usage: boxa::route_hosts <project> [port]
boxa::route_hosts() {
    local project="$1" port="${2:-}"
    _boxa::load_dns_conf
    local prefix=""
    [ -n "$port" ] && prefix="${port}."
    printf '%s%s.%s\n' "$prefix" "$project" "$BOXA_LOCAL_TLD"
    printf '%s%s.127.0.0.1.%s\n' "$prefix" "$project" "$_BOXA_EXTERNAL_PROVIDER"
}

# Yield the single user-facing hostname for the active mode. Used by display
# call sites (`boxa port`, `boxa ports`, `boxa ls`). Mode switching
# only changes what this prints; Traefik routes (built from route_hosts)
# are unaffected.
#
# Usage: boxa::route_host_display <project> [port]
boxa::route_host_display() {
    local project="$1" port="${2:-}"
    _boxa::load_dns_conf
    if [ -n "$port" ]; then
        printf '%s.%s.%s' "$port" "$project" "$_BOXA_ACTIVE_DOMAIN"
    else
        printf '%s.%s' "$project" "$_BOXA_ACTIVE_DOMAIN"
    fi
}

# Print a regex matching all per-project volume names. Derived from
# BOXA_PROJECT_VOLUME_SUFFIXES so adding a suffix updates every reverse
# match site.
#
# Usage: pattern=$(boxa::project_volume_regex)
boxa::project_volume_regex() {
    local IFS='|'
    printf '^boxa-.+-(%s)$' "${BOXA_PROJECT_VOLUME_SUFFIXES[*]}"
}

# Derive every name from a host filesystem path. Sanitizes the basename and
# exports BOXA_* globals.
#
# Usage: boxa::names_from_path <path>
boxa::names_from_path() {
    local path="$1"
    BOXA_PROJECT_NAME_RAW="$(basename "$path")"
    _boxa::derive_from_project_name "$(boxa::sanitize "$BOXA_PROJECT_NAME_RAW")"
}

# Derive every name from a user-supplied token (e.g. `boxa foo`). Sanitizes
# the token so the result is identical for `boxa foo bar` and `boxa foo-bar`
# — fixes the latent inconsistency at docker-run.sh attach-by-name.
#
# Usage: boxa::names_from_token <token>
boxa::names_from_token() {
    local token="$1"
    BOXA_PROJECT_NAME_RAW="$token"
    _boxa::derive_from_project_name "$(boxa::sanitize "$token")"
}

# --- Private -----------------------------------------------------------------

_boxa::derive_from_project_name() {
    BOXA_PROJECT_NAME="$1"
    BOXA_CONTAINER_NAME="boxa-${BOXA_PROJECT_NAME}"
    BOXA_HOSTNAME="${BOXA_PROJECT_NAME}"
    BOXA_VOL_HISTORY="$(boxa::volume_name "$BOXA_PROJECT_NAME" history)"
    BOXA_VOL_DOCKER="$(boxa::volume_name "$BOXA_PROJECT_NAME" docker)"
    BOXA_WORKSPACE_ALIAS="/workspace/${BOXA_PROJECT_NAME}"
}
