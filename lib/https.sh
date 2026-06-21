# shellcheck shell=bash
# =============================================================================
# Boxa HTTPS state — schema + load/store helpers for ~/.config/boxa/https.conf
# =============================================================================
# Sourced by host-side scripts (scripts/dns-install.sh, future docker-run.sh
# bootstrap_traefik / apply_port_routes). Owns the contract that decides whether
# boxa serves HTTPS:
#
#   active=false                  # Phase 4 flips this; until then HTTP-only.
#   optout=false                  # set true after a user "n" at the Phase 6 prompt.
#   ca_fingerprint=               # sha256 of mkcert rootCA.pem at install time.
#   mkcert_version=               # version recorded at CA install.
#   ca_installed_at=              # ISO-8601 UTC timestamp of the install.
#   ca_installed_platforms=       # comma-separated taxonomy: linux|macos|windows
#                                 # — `windows` is reserved for the WSL2 phase 6
#                                 # trust install; phase 1 only ever writes
#                                 # `linux` or `macos`.
#
# HTTPS state is binary: a caller decides what to do by branching on
# `boxa::https_active`, never on a half-set combination of the other fields.
# Every accessor returns a defined default when the file is missing or a field
# is unset, so a caller never has to special-case absence.
#
# Parsing is strict: `key=value` per line, `#` comments, fixed allow-list of
# keys. We deliberately do NOT `source` the file — ambient pollution from a
# stray line would silently change boxa behavior elsewhere.
# =============================================================================

# --- Internal cache ----------------------------------------------------------

# Override target via $BOXA_HTTPS_CONF (used by tests).
_BOXA_HTTPS_CONF_LOADED=
_BOXA_HTTPS_ACTIVE=
_BOXA_HTTPS_OPTOUT=
_BOXA_HTTPS_CA_FINGERPRINT=
_BOXA_HTTPS_MKCERT_VERSION=
_BOXA_HTTPS_CA_INSTALLED_AT=
_BOXA_HTTPS_CA_INSTALLED_PLATFORMS=

# Drop the cached https.conf state. Called by the writer after rewriting the
# file in-process, and by tests between seedings.
boxa::reset_https_cache() {
    _BOXA_HTTPS_CONF_LOADED=
    _BOXA_HTTPS_ACTIVE=
    _BOXA_HTTPS_OPTOUT=
    _BOXA_HTTPS_CA_FINGERPRINT=
    _BOXA_HTTPS_MKCERT_VERSION=
    _BOXA_HTTPS_CA_INSTALLED_AT=
    _BOXA_HTTPS_CA_INSTALLED_PLATFORMS=
}

# Resolve the runtime https.conf path. Single source so the writer and the
# loader can never disagree.
_https::conf_path() {
    printf '%s' "${BOXA_HTTPS_CONF:-$HOME/.config/boxa/https.conf}"
}

# Parse https.conf into the cache. Lazy — repeat calls in the same process
# return immediately. Matches lib/naming.sh's _boxa::load_dns_conf style:
# fixed key allow-list, comments stripped, whitespace tolerated, unknown keys
# ignored.
_boxa::load_https_conf() {
    [ -n "$_BOXA_HTTPS_CONF_LOADED" ] && return 0
    _BOXA_HTTPS_CONF_LOADED=1
    _BOXA_HTTPS_ACTIVE="false"
    _BOXA_HTTPS_OPTOUT="false"
    _BOXA_HTTPS_CA_FINGERPRINT=""
    _BOXA_HTTPS_MKCERT_VERSION=""
    _BOXA_HTTPS_CA_INSTALLED_AT=""
    _BOXA_HTTPS_CA_INSTALLED_PLATFORMS=""
    local conf
    conf="$(_https::conf_path)"
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
            active)
                case "$value" in true|false) _BOXA_HTTPS_ACTIVE="$value" ;; esac ;;
            optout)
                case "$value" in true|false) _BOXA_HTTPS_OPTOUT="$value" ;; esac ;;
            ca_fingerprint)         _BOXA_HTTPS_CA_FINGERPRINT="$value" ;;
            mkcert_version)         _BOXA_HTTPS_MKCERT_VERSION="$value" ;;
            ca_installed_at)        _BOXA_HTTPS_CA_INSTALLED_AT="$value" ;;
            ca_installed_platforms) _BOXA_HTTPS_CA_INSTALLED_PLATFORMS="$value" ;;
        esac
    done < "$conf"
}

# --- Public accessors --------------------------------------------------------

# Each accessor is the single read site for one field. Callers branch on these
# rather than re-parsing the file. Returns 0/1 for the boolean accessors so
# they compose cleanly with `if`:
#
#   if boxa::https_active; then ... fi
#
# String accessors always print (possibly empty) — never fail — so command
# substitutions don't need rc guards.

boxa::https_active() {
    _boxa::load_https_conf
    [ "$_BOXA_HTTPS_ACTIVE" = "true" ]
}

boxa::https_optout() {
    _boxa::load_https_conf
    [ "$_BOXA_HTTPS_OPTOUT" = "true" ]
}

boxa::ca_fingerprint() {
    _boxa::load_https_conf
    printf '%s' "$_BOXA_HTTPS_CA_FINGERPRINT"
}

boxa::mkcert_version() {
    _boxa::load_https_conf
    printf '%s' "$_BOXA_HTTPS_MKCERT_VERSION"
}

boxa::ca_installed_at() {
    _boxa::load_https_conf
    printf '%s' "$_BOXA_HTTPS_CA_INSTALLED_AT"
}

boxa::ca_installed_platforms() {
    _boxa::load_https_conf
    printf '%s' "$_BOXA_HTTPS_CA_INSTALLED_PLATFORMS"
}

# --- Writer ------------------------------------------------------------------

# Rewrite a single field in https.conf, preserving unknown lines and comments.
# Mirrors `_dns::write_mode` in scripts/dns-install.sh — same awk-based
# replace-or-append pass — so the two state files share a single update
# pattern and stay byte-identical across versions of the tool.
#
# We write in-place via `cat > $conf` rather than `mktemp + mv`, per
# feedback_bindmount_inode: even though https.conf is not bind-mounted today,
# Phase 4 may end up mounting parts of $BOXA_HTTPS_DIR into Traefik, and
# keeping the inode stable removes a footgun before it grows teeth.
#
# Usage: boxa::write_https_field <key> <value>
boxa::write_https_field() {
    local key="$1" value="${2:-}"
    case "$key" in
        active|optout|ca_fingerprint|mkcert_version|ca_installed_at|ca_installed_platforms) ;;
        *) echo "write_https_field: refusing to write unknown key '$key'" >&2; return 1 ;;
    esac
    local conf rendered conf_dir
    conf="$(_https::conf_path)"
    conf_dir="$(dirname "$conf")"
    if ! mkdir -p "$conf_dir" 2>/dev/null; then
        echo "write_https_field: cannot create $conf_dir" >&2
        return 1
    fi
    if [ -f "$conf" ]; then
        rendered="$(awk -v k="$key" -v v="$value" '
            BEGIN { seen=0 }
            {
                line=$0
                stripped=line
                sub(/^[[:space:]]+/, "", stripped)
                sub(/[[:space:]]+$/, "", stripped)
                if (stripped ~ "^"k"[[:space:]]*=") {
                    print k "=" v
                    seen=1
                    next
                }
                print line
            }
            END { if (!seen) print k "=" v }
        ' "$conf")"
    else
        rendered="# Boxa HTTPS state — managed by boxa; safe to delete to reset."$'\n'"$key=$value"
    fi
    # Capture the redirect's rc explicitly: if we let the trailing
    # `boxa::reset_https_cache` be the function's last command, its rc=0
    # would mask a write failure and callers' `|| _warn` would never fire.
    if ! printf '%s\n' "$rendered" > "$conf" 2>/dev/null; then
        echo "write_https_field: cannot write $conf" >&2
        return 1
    fi
    boxa::reset_https_cache
}

# Append a platform tag to ca_installed_platforms without introducing
# duplicates. Used by _dns::install_ca after a successful trust-store install
# so re-running `dns-install` on the same machine doesn't grow the list with
# repeats and so that Phase 6's WSL2 Windows-trust pass can additively record
# `windows` alongside the existing `linux` entry.
#
# Usage: boxa::add_ca_installed_platform <name>
boxa::add_ca_installed_platform() {
    local platform="$1"
    [ -n "$platform" ] || return 0
    local current next
    current="$(boxa::ca_installed_platforms)"
    case ",$current," in
        *",$platform,"*) return 0 ;;
    esac
    if [ -z "$current" ]; then
        next="$platform"
    else
        next="$current,$platform"
    fi
    boxa::write_https_field ca_installed_platforms "$next"
}
