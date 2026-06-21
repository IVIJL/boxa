# shellcheck shell=bash
# =============================================================================
# Boxa mkcert wrapper — single source of MKCERT_BIN and CA-install plumbing
# =============================================================================
# Sourced by host-side scripts (dns-install.sh, future docker-run.sh cert
# lifecycle hooks). Encapsulates:
#   - mkcert binary discovery   (_mkcert::resolve_bin)
#   - minimum-version assertion (_mkcert::version_check)
#   - CAROOT + fingerprint      (_mkcert::caroot / _mkcert::ca_fingerprint)
#   - CA install                (seed_local_ca)
#
# Phase 1 of the HTTPS rollout only handles the Linux/macOS-native CA install
# path. Windows-side trust install (for WSL2) is deferred to Phase 6 — see
# local-plan-https-mkcert.md and ADR 0008.
#
# The minimum mkcert version is `1.4.4` — the first release that reliably
# emits a stable -CAROOT layout and writes Linux NSS / macOS Keychain on
# `-install` without manual follow-up. ADR 0008 § "mkcert version pin".
# =============================================================================

BOXA_MKCERT_MIN_VERSION="1.4.4"

# Cached binary path. Resolved lazily in _mkcert::resolve_bin.
_BOXA_MKCERT_BIN=

# Test whether a binary path is mkcert >= BOXA_MKCERT_MIN_VERSION. Used by
# resolve_bin to skip stale candidates, and shared with install.sh so the
# installer applies exactly the same gate (no risk of resolve_bin rejecting
# something install.sh accepted).
#
# Returns 0 when usable. Returns 1 for missing path, non-executable, non-mkcert
# binary, or version below the floor.
_mkcert::probe() {
    local bin="$1"
    [ -n "$bin" ] && [ -x "$bin" ] || return 1
    local v
    v="$("$bin" -version 2>/dev/null | head -n1)" || return 1
    v="${v#v}"
    [ -n "$v" ] || return 1
    local major minor patch rest
    major="${v%%.*}"
    rest="${v#*.}"
    minor="${rest%%.*}"
    patch="${rest#*.}"
    patch="${patch%%[!0-9]*}"
    : "${major:=0}"
    : "${minor:=0}"
    : "${patch:=0}"
    if [ "$major" -lt 1 ] \
       || { [ "$major" -eq 1 ] && [ "$minor" -lt 4 ]; } \
       || { [ "$major" -eq 1 ] && [ "$minor" -eq 4 ] && [ "$patch" -lt 4 ]; }; then
        return 1
    fi
}

# Print the absolute path to a usable mkcert binary, or fail (rc=1) if no
# candidate meets BOXA_MKCERT_MIN_VERSION.
#
# Resolution order:
#   1. system install on PATH (brew on macOS, distro packages on Linux)
#   2. bundled binary at ~/.local/bin/mkcert (installed by install.sh)
#
# Both candidates are version-gated via _mkcert::probe so a stale system
# install transparently falls through to the bundled pinned version that
# install.sh maintains.
#
# Cached for the lifetime of the shell to avoid repeated PATH walks; reset
# via boxa::reset_mkcert_cache after a fresh install or upgrade in-process.
_mkcert::resolve_bin() {
    if [ -n "$_BOXA_MKCERT_BIN" ]; then
        printf '%s' "$_BOXA_MKCERT_BIN"
        return 0
    fi
    local candidate
    if candidate="$(command -v mkcert 2>/dev/null)" && _mkcert::probe "$candidate"; then
        _BOXA_MKCERT_BIN="$candidate"
    elif _mkcert::probe "$HOME/.local/bin/mkcert"; then
        _BOXA_MKCERT_BIN="$HOME/.local/bin/mkcert"
    else
        return 1
    fi
    printf '%s' "$_BOXA_MKCERT_BIN"
}

# Drop the cached binary path. For tests and for install.sh post-install
# rediscovery within the same shell.
boxa::reset_mkcert_cache() {
    _BOXA_MKCERT_BIN=
}

# Print the installed mkcert version (without leading `v`), or fail.
_mkcert::version() {
    local bin
    bin="$(_mkcert::resolve_bin)" || return 1
    local v
    v="$("$bin" -version 2>/dev/null | head -n1)" || return 1
    v="${v#v}"
    [ -n "$v" ] || return 1
    printf '%s' "$v"
}

# Return success iff a usable mkcert >= BOXA_MKCERT_MIN_VERSION is reachable.
# Thin wrapper around resolve_bin (which version-gates via _mkcert::probe); the
# wrapper exists so callers can express the intent and get a stderr diagnostic
# without having to duplicate the "no usable binary" wording themselves.
_mkcert::version_check() {
    if ! _mkcert::resolve_bin >/dev/null 2>&1; then
        echo "mkcert: no usable binary >= $BOXA_MKCERT_MIN_VERSION (looked on PATH and \$HOME/.local/bin)" >&2
        return 1
    fi
}

# Print the mkcert CAROOT directory, or fail (the directory may not exist
# until `mkcert -install` has been run).
_mkcert::caroot() {
    local bin
    bin="$(_mkcert::resolve_bin)" || return 1
    "$bin" -CAROOT 2>/dev/null
}

# Portable SHA-256 of a file: GNU coreutils ships `sha256sum`, macOS ships
# `shasum -a 256`. Both emit `<hash><space><filename>` so a single awk
# extracts the hash field. Returns 1 if neither tool is available or the
# file cannot be read.
_mkcert::_sha256_file() {
    local path="$1"
    [ -n "$path" ] && [ -f "$path" ] || return 1
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$path" 2>/dev/null | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$path" 2>/dev/null | awk '{print $1}'
    else
        return 1
    fi
}

# Print the SHA-256 fingerprint of the local mkcert root CA (rootCA.pem),
# or fail if it has not been generated yet. Used to detect CA churn — a
# changed fingerprint invalidates every issued leaf cert.
_mkcert::ca_fingerprint() {
    local caroot
    caroot="$(_mkcert::caroot)" || return 1
    [ -n "$caroot" ] && [ -f "$caroot/rootCA.pem" ] || return 1
    _mkcert::_sha256_file "$caroot/rootCA.pem"
}

# Install the mkcert local root CA into the host's native trust store.
#
# Native behaviour by platform:
#   - Linux native: writes /usr/local/share/ca-certificates/mkcert-rootCA.pem
#     and runs update-ca-certificates. Needs root → sudo prompt fires.
#     Firefox/Chrome NSS DB is also updated when certutil is available.
#   - macOS: imports into the System Keychain (Touch ID / password prompt).
#   - WSL2: installs into the WSL2 Linux trust store only. The Windows host
#     trust store is handled separately in Phase 6 of the HTTPS rollout.
#
# `mkcert -install`'s native progress output is redirected to stderr so this
# function's stdout stays clean — callers may safely do
# `caroot="$(seed_local_ca)"` to capture just the CAROOT path.
#
# Returns 0 on success and prints the CAROOT path. Non-zero on any failure;
# never fatal (no `set -e` traps inside).
seed_local_ca() {
    local bin
    if ! bin="$(_mkcert::resolve_bin)"; then
        echo "seed_local_ca: no usable mkcert >= $BOXA_MKCERT_MIN_VERSION — install or upgrade it first" >&2
        return 1
    fi
    if ! "$bin" -install >&2; then
        echo "seed_local_ca: 'mkcert -install' failed" >&2
        return 1
    fi
    local caroot
    caroot="$("$bin" -CAROOT 2>/dev/null)"
    if [ -z "$caroot" ] || [ ! -f "$caroot/rootCA.pem" ]; then
        echo "seed_local_ca: CAROOT/rootCA.pem missing after install" >&2
        return 1
    fi
    printf '%s' "$caroot"
}
