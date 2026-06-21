#!/bin/bash
set -euo pipefail
# Standalone mkcert provisioner. Idempotent: skips when a usable
# (>= BOXA_MKCERT_MIN_VERSION) mkcert is already on PATH or at the
# pinned $HOME/.local/bin/mkcert location. Otherwise it downloads the
# pinned release from GitHub (SHA-256 verified) and lands it at the path
# lib/mkcert.sh probes.
#
# This used to live inline inside install.sh. Extracted so the HTTPS
# upgrade orchestration (`_dns::install_ca` from scripts/dns-install.sh
# and `_boxa::run_https_upgrade` from docker-run.sh) can call it on
# its own — without dragging in install.sh's repo-clone / symlink-replace
# side effects, which would be destructive for users who installed
# boxa at a custom path (e.g. a developer clone outside
# ~/.local/share/boxa).
#
# Side effects (strictly scoped):
#   - $HOME/.local/bin/mkcert (mkdir + write + chmod 0755)
#   - With --with-nss on Linux without certutil: pkg_install libnss3-tools
#     (or equivalent for the detected package manager) via sudo.
#
# What it explicitly does NOT touch:
#   - /usr/local/bin/boxa symlink
#   - ~/.local/share/boxa repo
#   - any shell rc file
#   - any other dependency install.sh manages
#
# Exits 0 when a usable mkcert is present at the end of the run (whether
# it was already there or freshly installed). Exits non-zero on a real
# install failure (network, hash mismatch, unsupported platform).

# --- Constants ---------------------------------------------------------------

# Pinned mkcert release. Bumping these in lockstep with lib/mkcert.sh's
# BOXA_MKCERT_MIN_VERSION keeps `_mkcert::probe` and this downloader
# aligned: a stale lib version would otherwise reject the freshly-pinned
# binary downloaded here.
MKCERT_VERSION="1.4.4"
MKCERT_BIN_PATH="${HOME}/.local/bin/mkcert"

# SHA-256 hashes for the upstream release binaries hosted at
# https://github.com/FiloSottile/mkcert/releases/download/v${MKCERT_VERSION}/.
# Bump MKCERT_VERSION and the table together.
_mkcert_sha256() {
    case "$1" in
        linux-amd64)  echo 6d31c65b03972c6dc4a14ab429f2928300518b26503f58723e532d1b0a3bbb52 ;;
        linux-arm64)  echo b98f2cc69fd9147fe4d405d859c57504571adec0d3611c3eefd04107c7ac00d0 ;;
        linux-arm)    echo 2f22ff62dfc13357e147e027117724e7ce1ff810e30d2b061b05b668ecb4f1d7 ;;
        darwin-amd64) echo a32dfab51f1845d51e810db8e47dcf0e6b51ae3422426514bf5a2b8302e97d4e ;;
        darwin-arm64) echo c8af0df44bce04359794dad8ea28d750437411d632748049d08644ffb66a60c6 ;;
        *)            return 1 ;;
    esac
}

# --- Output helpers ----------------------------------------------------------

# stderr — keeps stdout reserved for callers who want to parse a final
# success line. Today both install.sh and _dns::install_ca just check rc,
# but locking that contract down early lets a later caller (e.g. CI) sniff
# the final binary path without parsing colored output.
CYAN='\033[1;36m'; YELLOW='\033[1;33m'; GREEN='\033[1;32m'; RED='\033[1;31m'; NC='\033[0m'

_info() { printf "${CYAN}==> %s${NC}\n" "$*" >&2; }
_ok()   { printf "${GREEN}==> %s${NC}\n" "$*" >&2; }
_warn() { printf "${YELLOW}==> WARN: %s${NC}\n" "$*" >&2; }
_fail() { printf "${RED}==> ERROR: %s${NC}\n" "$*" >&2; }
_msg()  { printf '  %s\n' "$*" >&2; }

has() { command -v "$1" >/dev/null 2>&1; }

# --- Argument parsing --------------------------------------------------------

WITH_NSS=false
for arg in "$@"; do
    case "$arg" in
        --with-nss) WITH_NSS=true ;;
        --help|-h)
            cat <<'USAGE'
Usage: install-mkcert.sh [--with-nss]

Idempotently install mkcert at $HOME/.local/bin/mkcert (pinned version,
SHA-256 verified). Skips when a usable mkcert >= the pinned floor is
already on PATH.

Options:
  --with-nss   Linux only: also `pkg_install libnss3-tools` (or the
               equivalent) when `certutil` is missing, so mkcert -install
               can write Firefox/Chrome's NSS trust DB without a second
               manual step.
USAGE
            exit 0
            ;;
        *) _fail "Unknown argument: $arg"; exit 2 ;;
    esac
done

# --- Source the version-gate from lib/mkcert.sh ------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOXA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=../lib/mkcert.sh disable=SC1091
source "$BOXA_DIR/lib/mkcert.sh"

# --- Platform detection ------------------------------------------------------

# Returns one of: linux-amd64, linux-arm64, linux-arm, darwin-amd64, darwin-arm64.
# Anything else → rc=1 so the caller can skip cleanly (per ADR 0008: graceful
# degradation to HTTP-only on unsupported platforms).
_mkcert_platform() {
    local os arch
    case "$(uname -s)" in
        Linux)  os="linux" ;;
        Darwin) os="darwin" ;;
        *) return 1 ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64)   arch="amd64" ;;
        aarch64|arm64)  arch="arm64" ;;
        armv7l|armv6l)  arch="arm" ;;
        *) return 1 ;;
    esac
    printf '%s-%s\n' "$os" "$arch"
}

# --- Optional NSS tools install (Linux only) ---------------------------------

# Detect the host's package manager so we can pkg_install the matching NSS
# tools package. Mirrors install.sh's detect_os logic but trimmed: we only
# need the cases where mkcert NSS support is useful.
_detect_pm() {
    if has apt-get; then echo apt-get; return; fi
    if has dnf;     then echo dnf;     return; fi
    if has pacman;  then echo pacman;  return; fi
    if has zypper;  then echo zypper;  return; fi
    if has apk;     then echo apk;     return; fi
    return 1
}

_pkg_install() {
    local pm pkg="$1"
    pm="$(_detect_pm)" || return 1
    case "$pm" in
        apt-get) sudo apt-get install -y "$pkg" ;;
        dnf)     sudo dnf install -y "$pkg" ;;
        pacman)  sudo pacman -S --noconfirm "$pkg" ;;
        zypper)  sudo zypper install -y "$pkg" ;;
        apk)     sudo apk add "$pkg" ;;
    esac
}

# Without certutil mkcert -install logs a warning and skips Firefox/Chrome's
# NSS database. Installing NSS tools proactively keeps the eventual UAC-less
# CA install on Linux complete on the first try. Macos uses the Keychain
# directly; no NSS install needed.
install_mkcert_nss_tools() {
    if [ "$(uname -s)" != "Linux" ]; then
        return 0
    fi
    if has certutil; then
        _msg "NSS tools (certutil) already present — skipping."
        return 0
    fi
    local pm nss_pkg=""
    pm="$(_detect_pm)" || { _warn "no known package manager — Firefox/Chrome trust will be incomplete."; return 0; }
    case "$pm" in
        apt-get) nss_pkg="libnss3-tools" ;;
        dnf)     nss_pkg="nss-tools" ;;
        pacman)  nss_pkg="nss" ;;
        zypper)  nss_pkg="mozilla-nss-tools" ;;
        apk)     nss_pkg="nss-tools" ;;
    esac
    if [ -z "$nss_pkg" ]; then
        _warn "NSS tools: no known package for $pm; Firefox/Chrome trust will be incomplete."
        return 0
    fi
    _info "Installing NSS tools ($nss_pkg) for browser trust store support..."
    if _pkg_install "$nss_pkg"; then
        _ok "NSS tools installed."
    else
        _warn "Could not install $nss_pkg; Firefox/Chrome trust will be incomplete."
    fi
}

# --- Main --------------------------------------------------------------------

# Step 1: Is a usable mkcert already reachable? Skip every download path
# if so. Reuses the lib's probe so install-time and runtime agree on what
# "usable" means — a stale system mkcert (old brew, old distro package)
# rejected by the lib must also be rejected here, otherwise we'd accept
# it now and the runtime would refuse it later.
existing=""
for candidate in "$(command -v mkcert 2>/dev/null || true)" "$MKCERT_BIN_PATH"; do
    [ -z "$candidate" ] && continue
    if _mkcert::probe "$candidate"; then
        existing="$candidate"
        break
    fi
done

if [ -n "$existing" ]; then
    _msg "Found usable mkcert at $existing ($("$existing" -version 2>/dev/null | head -n1)). Skipping download."
    [ "$WITH_NSS" = "true" ] && install_mkcert_nss_tools
    # Caller's contract: when the script exits 0, a usable mkcert exists
    # at MKCERT_BIN_PATH OR somewhere on PATH that _mkcert::probe will
    # accept. Both are acceptable end-states.
    printf '%s\n' "$existing"
    exit 0
fi

# Step 2: macOS users with brew get the canonical formula. brew handles
# its own NSS plumbing, so --with-nss is a no-op on that path.
if [ "$(uname -s)" = "Darwin" ] && has brew; then
    local_brew_cmd="install"
    if brew list mkcert >/dev/null 2>&1; then
        local_brew_cmd="upgrade"
    fi
    _info "Running brew $local_brew_cmd mkcert..."
    if brew "$local_brew_cmd" mkcert; then
        # Re-resolve via the lib so we report the path that runtime will
        # actually pick — brew may put it on PATH instead of MKCERT_BIN_PATH.
        boxa::reset_mkcert_cache
        if final="$(_mkcert::resolve_bin)"; then
            _ok "mkcert installed via brew."
            printf '%s\n' "$final"
            exit 0
        fi
    fi
    _warn "brew $local_brew_cmd mkcert did not yield a usable binary; falling back to GitHub release."
fi

# Step 3: GitHub release path. Works on every supported Linux/macOS arch.
if ! platform="$(_mkcert_platform)"; then
    _fail "mkcert: unsupported platform ($(uname -s)/$(uname -m))."
    exit 1
fi
if ! expected="$(_mkcert_sha256 "$platform")"; then
    _fail "mkcert: no SHA-256 pinned for $platform."
    exit 1
fi

url="https://github.com/FiloSottile/mkcert/releases/download/v${MKCERT_VERSION}/mkcert-v${MKCERT_VERSION}-${platform}"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
_info "Downloading mkcert v${MKCERT_VERSION} ($platform)..."
if ! curl --proto '=https' --tlsv1.2 -fsSL -o "$tmp" "$url"; then
    _fail "mkcert: download failed from $url."
    exit 1
fi

# Portable hash: macOS ships `shasum -a 256`, not GNU `sha256sum`. The
# sourced lib already encapsulates that choice in _mkcert::_sha256_file;
# calling it here keeps the darwin-* fallback path working when brew
# install/upgrade has failed and we need the GitHub release.
if ! actual="$(_mkcert::_sha256_file "$tmp")" || [ -z "$actual" ]; then
    _fail "mkcert: could not compute SHA-256 of downloaded artifact (no sha256sum / shasum?)."
    exit 1
fi
if [ "$actual" != "$expected" ]; then
    _fail "mkcert: SHA-256 mismatch (expected $expected, got $actual)."
    exit 1
fi

mkdir -p "$(dirname "$MKCERT_BIN_PATH")"
mv "$tmp" "$MKCERT_BIN_PATH"
chmod 0755 "$MKCERT_BIN_PATH"
# Disarm the trap — the tmp file is now at its final home.
trap - EXIT

_ok "mkcert v${MKCERT_VERSION} installed to $MKCERT_BIN_PATH."
[ "$WITH_NSS" = "true" ] && install_mkcert_nss_tools

# Confirm the lib will accept what we just dropped — catches a packaging
# regression (wrong arch, corrupt zip, etc.) where the file landed but
# `-version` fails to parse.
boxa::reset_mkcert_cache
if ! final="$(_mkcert::resolve_bin)"; then
    _fail "mkcert: post-install probe failed at $MKCERT_BIN_PATH — file may be corrupt."
    exit 1
fi

printf '%s\n' "$final"
