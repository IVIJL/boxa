#!/bin/bash
set -euo pipefail
# Per-OS host-side DNS resolver setup so *.test hostnames route to 127.0.0.1
# (the dnsmasq container started by docker-run.sh::bootstrap_dns). Companion
# to ADR 0007.
#
# Actions:
#   install   detect platform, configure resolver, verify, persist mode
#   status    show platform + active mode + resolver-file state + verification
#   uninstall remove resolver entries and ~/.config/boxa/dns.conf
#
# Mode preference is persisted in ~/.config/boxa/dns.conf
# (override path with BOXA_DNS_CONF). lib/naming.sh parses the file
# strictly; we write it with a key=value updater that preserves unknown
# lines.
#
# Failures cascade to external mode rather than aborting: WARNINGS=()
# collects every issue and prints a colored end-summary so the user knows
# exactly which mode they ended up in and why.

CYAN='\033[1;36m'; YELLOW='\033[1;33m'; GREEN='\033[1;32m'; RED='\033[1;31m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOXA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source-path=SCRIPTDIR source=../lib/naming.sh disable=SC1091
source "$BOXA_DIR/lib/naming.sh"
# shellcheck source-path=SCRIPTDIR source=../lib/mkcert.sh disable=SC1091
source "$BOXA_DIR/lib/mkcert.sh"
# shellcheck source-path=SCRIPTDIR source=../lib/https.sh disable=SC1091
source "$BOXA_DIR/lib/https.sh"
# shellcheck source-path=SCRIPTDIR source=../lib/cert.sh disable=SC1091
source "$BOXA_DIR/lib/cert.sh"

DNS_CONF_FILE="${BOXA_DNS_CONF:-$HOME/.config/boxa/dns.conf}"
DEFAULT_EXTERNAL_DOMAIN="127.0.0.1.sslip.io"
DEFAULT_EXTERNAL_PROVIDER="sslip.io"

WARNINGS=()
_warn() {
    WARNINGS+=("$1")
    printf "${YELLOW}WARN: %s${NC}\n" "$1" >&2
}
_info() { printf "${CYAN}%s${NC}\n" "$*"; }
_ok()   { printf "${GREEN}%s${NC}\n" "$*"; }
_fail() { printf "${RED}%s${NC}\n" "$*" >&2; }

usage() {
    cat <<USAGE
Usage: dns-install.sh [install] [--local | --external | --auto]
       dns-install.sh status
       dns-install.sh uninstall
       dns-install.sh purge-ca
       dns-install.sh --enable-https
       dns-install.sh --disable-https

Actions:
  install         Configure host resolver so *.test → 127.0.0.1 (default).
  status          Show platform, active mode, resolver state, verification.
  uninstall       Remove resolver config (per OS) and dns.conf.
  purge-ca        Remove mkcert root CA from native trust stores (WSL2: also
                  Windows certutil Root store + Firefox policies.json merge),
                  delete https.conf, and remove the mkcert CAROOT directory.
                  Fires a UAC prompt on WSL2 / sudo on Linux native.
  --enable-https  Install CA into host trust stores (WSL2: triggers UAC for
                  the Windows side once) and flip https.conf active=true.
  --disable-https Set https.conf active=false (CA stays installed; restore
                  HTTP-only on next 'boxa <project>').

Mode flags (install only):
  --auto       Try local; fall back to external on conflict/failure (default).
  --local      Force local mode; do not fall back.
  --external   Skip resolver setup; persist external (*.${DEFAULT_EXTERNAL_DOMAIN}).
USAGE
}

# --- Platform detection ------------------------------------------------------

# Returns one of: macos | wsl2 | linux-resolved | linux-nm | unsupported.
# WSL2 is checked before generic Linux because it needs two-sided setup
# (Linux-internal resolver + Windows NRPT) that other Linux variants do not.
_dns::detect_platform() {
    local uname_s
    uname_s="$(uname -s 2>/dev/null || echo Unknown)"
    case "$uname_s" in
        Darwin) echo "macos"; return 0 ;;
        Linux)  ;;
        *) echo "unsupported"; return 0 ;;
    esac
    if grep -qi microsoft /proc/version 2>/dev/null; then
        echo "wsl2"
        return 0
    fi
    if command -v systemctl >/dev/null 2>&1 \
        && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        echo "linux-resolved"
        return 0
    fi
    if _dns::nm_dnsmasq_enabled; then
        echo "linux-nm"
        return 0
    fi
    echo "unsupported"
}

# Check whether NetworkManager is configured to use the dnsmasq plugin
# (the only mode where the NM drop-in approach works).
_dns::nm_dnsmasq_enabled() {
    local rc=0
    grep -hE '^[[:space:]]*dns[[:space:]]*=' \
        /etc/NetworkManager/NetworkManager.conf \
        /etc/NetworkManager/conf.d/*.conf 2>/dev/null \
        | grep -q dnsmasq || rc=$?
    return "$rc"
}

# --- Pre-flight --------------------------------------------------------------

# Is port 53 currently held by something that would conflict with us?
# Returns 0 (yes) on conflict; 1 if free or already ours.
#
# Docker publishes boxa_dns on 127.0.0.1:53 specifically. The conflict
# set is therefore narrow: anything bound to 127.0.0.1:53 itself, or to a
# wildcard (0.0.0.0:53 / *:53 / [::]:53 / [::1]:53) that would also serve
# 127.0.0.1. Resolver listeners on *other* loopback addresses are fine:
#  - systemd-resolved listens on 127.0.0.53:53
#  - NetworkManager-dnsmasq listens on 127.0.1.1:53
# Both coexist with a Docker bind on 127.0.0.1:53, and the per-TLD routing
# we install (`Domains=~test` / `server=/test/...`) is what makes them
# forward .test queries into our container.
_dns::port_53_held_by_other() {
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx boxa_dns; then
        return 1
    fi
    local listeners=""
    if command -v ss >/dev/null 2>&1; then
        listeners="$(ss -lntu 2>/dev/null | awk 'NR>1 {print $5}')"
    elif command -v lsof >/dev/null 2>&1; then
        listeners="$({ lsof -nP -iTCP:53 -sTCP:LISTEN 2>/dev/null
                       lsof -nP -iUDP:53 2>/dev/null
                     } | awk 'NR>1 {print $9}')"
    else
        return 1
    fi
    [ -z "$listeners" ] && return 1
    local rc=1
    printf '%s\n' "$listeners" \
        | grep -qE '^(127\.0\.0\.1|0\.0\.0\.0|\*|\[::\]|\[::1\]):53$' && rc=0
    return "$rc"
}

_dns::sudo_available() {
    command -v sudo >/dev/null 2>&1
}

# --- Resolver writers (per platform) -----------------------------------------

_dns::install_macos() {
    local target="/etc/resolver/$BOXA_LOCAL_TLD"
    _info "Installing $target (sudo)..."
    if ! _dns::sudo_available; then
        _warn "sudo not available — cannot write $target"
        return 1
    fi
    # /etc/resolver does not exist on a fresh macOS — the Apple Resolver
    # framework only reads it when present. Create it before the first
    # entry; subsequent installs are no-ops thanks to `-p`.
    if ! sudo mkdir -p "$(dirname "$target")"; then
        _warn "Failed to create $(dirname "$target")"
        return 1
    fi
    if ! echo "nameserver 127.0.0.1" | sudo tee "$target" >/dev/null; then
        _warn "Failed to write $target"
        return 1
    fi
}

_dns::install_linux_resolved() {
    local drop="/etc/systemd/resolved.conf.d/boxa.conf"
    _info "Installing systemd-resolved drop-in $drop (sudo)..."
    if ! _dns::sudo_available; then
        _warn "sudo not available — cannot write $drop"
        return 1
    fi
    sudo mkdir -p "$(dirname "$drop")"
    if ! printf '%s\n' \
        "# Managed by boxa dns-install — do not edit." \
        "[Resolve]" \
        "DNS=127.0.0.1" \
        "Domains=~$BOXA_LOCAL_TLD" \
        | sudo tee "$drop" >/dev/null; then
        _warn "Failed to write $drop"
        return 1
    fi
    if ! sudo systemctl restart systemd-resolved 2>/dev/null; then
        _warn "systemd-resolved restart failed (drop-in written but not active)"
        return 1
    fi
}

_dns::install_linux_nm() {
    local drop="/etc/NetworkManager/dnsmasq.d/boxa.conf"
    _info "Installing NetworkManager-dnsmasq drop-in $drop (sudo)..."
    if ! _dns::sudo_available; then
        _warn "sudo not available — cannot write $drop"
        return 1
    fi
    sudo mkdir -p "$(dirname "$drop")"
    if ! echo "server=/$BOXA_LOCAL_TLD/127.0.0.1" \
        | sudo tee "$drop" >/dev/null; then
        _warn "Failed to write $drop"
        return 1
    fi
    if ! sudo systemctl reload NetworkManager 2>/dev/null; then
        _warn "NetworkManager reload failed (drop-in written but not active)"
        return 1
    fi
}

# WSL2 is two-sided: the WSL2 distro needs systemd-resolved (for WSL2-side
# curl) and the Windows host needs an NRPT rule (for browser + native Windows
# tools). Both ultimately route to 127.0.0.1:53 inside WSL2 via WSL2
# localhost forwarding. Either side may fail independently; we keep what
# worked and warn loudly about the rest. Returns success if at least one
# side is configured (callers treat that as "local mode is at least
# partially functional").
_dns::install_wsl2() {
    local linux_ok=0 windows_ok=0

    if command -v systemctl >/dev/null 2>&1 \
        && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        if _dns::install_linux_resolved; then
            linux_ok=1
        fi
    else
        _warn "systemd-resolved not active in this WSL2 distro — WSL2-side .test won't resolve. Enable it via /etc/wsl.conf [boot] systemd=true."
    fi

    if command -v powershell.exe >/dev/null 2>&1; then
        if _dns::install_wsl2_nrpt; then
            windows_ok=1
        fi
    else
        _warn "powershell.exe not found — cannot configure Windows NRPT. Run from a WSL2 distro with Windows interop enabled."
    fi

    if [ "$linux_ok" -eq 0 ] && [ "$windows_ok" -eq 0 ]; then
        return 1
    fi
}

# Encode the NRPT-add script as UTF-16LE base64 so the elevated PowerShell
# child reads it as a single -EncodedCommand argument, side-stepping the
# nested quoting nightmare of Start-Process -ArgumentList. UAC prompt
# appears here; user declining is detected by Get-DnsClientNrptRule
# returning the rule absent after the call.
_dns::install_wsl2_nrpt() {
    if ! command -v iconv >/dev/null 2>&1 || ! command -v base64 >/dev/null 2>&1; then
        _warn "iconv / base64 missing — cannot encode PowerShell command for NRPT setup."
        return 1
    fi
    local tld="$BOXA_LOCAL_TLD"
    local ps_cmd
    ps_cmd="if (-not (Get-DnsClientNrptRule -ErrorAction SilentlyContinue | Where-Object { \$_.Namespace -eq '.${tld}' -and \$_.NameServers -contains '127.0.0.1' })) { Add-DnsClientNrptRule -Namespace '.${tld}' -NameServers '127.0.0.1' }"
    local encoded
    encoded="$(printf '%s' "$ps_cmd" | iconv -t UTF-16LE | base64 -w0)"
    _info "Adding Windows NRPT rule (UAC will prompt)..."
    if ! powershell.exe -NoProfile -Command \
        "Start-Process powershell -Verb RunAs -Wait -ArgumentList '-NoProfile','-EncodedCommand','$encoded'" \
        >/dev/null 2>&1; then
        _warn "Windows NRPT setup failed or UAC declined — Windows browser will not resolve .${tld} URLs in local mode."
        return 1
    fi
}

# --- Post-verify -------------------------------------------------------------

# Returns 0 iff a probe *.test hostname resolves to 127.0.0.1. Tries libc
# resolver first (honors /etc/resolver on macOS, NRPT on Windows-as-WSL2-
# host, systemd-resolved on Linux), then falls back to dscacheutil (macOS)
# and `dig @127.0.0.1` (direct query to our dnsmasq).
_dns::resolver_works() {
    local probe="boxa-probe-$$.${BOXA_LOCAL_TLD}"
    if command -v getent >/dev/null 2>&1 \
        && getent hosts "$probe" 2>/dev/null | grep -q '127\.0\.0\.1'; then
        return 0
    fi
    if command -v dscacheutil >/dev/null 2>&1 \
        && dscacheutil -q host -a name "$probe" 2>/dev/null | grep -q '127\.0\.0\.1'; then
        return 0
    fi
    if command -v dig >/dev/null 2>&1 \
        && dig +short +time=1 +tries=1 "$probe" @127.0.0.1 2>/dev/null | grep -q '127\.0\.0\.1'; then
        return 0
    fi
    return 1
}

# --- dns.conf writer ---------------------------------------------------------

# Atomically rewrite ~/.config/boxa/dns.conf, replacing the values for
# `preferred`, `active_domain`, and `external_provider` while leaving any
# unknown lines and comments untouched.
_dns::write_mode() {
    local preferred="$1" active_domain="$2" provider="${3:-$DEFAULT_EXTERNAL_PROVIDER}"
    local conf="$DNS_CONF_FILE"
    mkdir -p "$(dirname "$conf")"
    local tmp
    tmp="$(mktemp "${conf}.XXXXXX")"
    if [ -f "$conf" ]; then
        awk -v p="$preferred" -v ad="$active_domain" -v pr="$provider" '
            BEGIN { seen_p=0; seen_ad=0; seen_pr=0 }
            /^[[:space:]]*preferred[[:space:]]*=/         { print "preferred=" p;         seen_p=1;  next }
            /^[[:space:]]*active_domain[[:space:]]*=/     { print "active_domain=" ad;    seen_ad=1; next }
            /^[[:space:]]*external_provider[[:space:]]*=/ { print "external_provider=" pr; seen_pr=1; next }
            { print }
            END {
                if (!seen_p)  print "preferred=" p
                if (!seen_ad) print "active_domain=" ad
                if (!seen_pr) print "external_provider=" pr
            }
        ' "$conf" > "$tmp"
    else
        {
            echo "# Boxa DNS preferences — managed by 'boxa dns-install'."
            echo "preferred=$preferred"
            echo "active_domain=$active_domain"
            echo "external_provider=$provider"
        } > "$tmp"
    fi
    mv "$tmp" "$conf"
    boxa::reset_dns_cache
}

# --- Install orchestration ---------------------------------------------------

# Loud, actionable end-banner for the degraded state: the user asked for (or
# defaulted to) local `.test` but the host resolver setup failed for a
# *fixable* reason (declined sudo / Touch ID, write error). We deliberately do
# NOT print a green "External mode active" here — a silent green fallback is
# exactly what leaves users staring at `.test` URLs that never resolve, with
# the real reason buried in the trailing WARN summary. Pairs with the degraded
# dns.conf write (preferred=local + active_domain=sslip) so URLs advertise the
# *working* sslip.io fallback meanwhile and self-heal retries the resolver on
# the next `boxa update`.
_dns::degraded_banner() {
    echo >&2
    printf "${RED}%s${NC}\n" "==> .test host resolver was NOT set up." >&2
    printf "${YELLOW}%s${NC}\n" \
        "    Boxa URLs use the sslip.io fallback for now: <port>.<project>.${DEFAULT_EXTERNAL_DOMAIN}" \
        "    To get the shorter .test URLs working, re-run:  boxa dns-install --local" \
        "    (boxa update retries this automatically once the resolver drop-in is missing)." >&2
}

# Prime a single sudo session before the resolver write and the CA install
# that follows it. Without this, macOS users face two independent auth
# moments — a terminal sudo for /etc/resolver/test, then a separate Touch ID
# for `mkcert -install`. Missing the first while approving the second silently
# strands .test on the sslip.io fallback while the CA looks fine — the exact
# failure this whole change is fixing. No-op when sudo is unavailable, already
# cached, or there is no TTY to prompt on (non-interactive installs).
_dns::prime_sudo() {
    _dns::sudo_available || return 0
    [ -t 0 ] || return 0
    case "$(_dns::detect_platform)" in
        macos|linux-resolved|linux-nm|wsl2) ;;
        *) return 0 ;;
    esac
    sudo -n true 2>/dev/null && return 0
    _info "Host DNS + CA setup needs elevated access — you may be prompted once."
    sudo -v 2>/dev/null || true
}

# Mode preferences: auto | local | external
#  - external          → no resolver setup, persist external mode.
#  - local             → setup required; fail loud on any error.
#  - auto (default)    → try local. A genuine, durable conflict (port 53 busy,
#                         unsupported platform) settles calmly into external
#                         mode. A *fixable* resolver-setup failure (declined
#                         sudo / write error) instead degrades LOUDLY and
#                         returns non-zero: dns.conf keeps preferred=local (so
#                         self-heal retries) while advertising sslip.io URLs,
#                         and the caller (install.sh) surfaces it as an action
#                         item rather than a silent success.
#                         A post-write verify failure stays in local mode and
#                         only warns — bootstrap_dns has not started dnsmasq
#                         yet on first install, so probing now would fall back
#                         spuriously.
_dns::install() {
    local mode_pref="${1:-auto}"
    local platform
    platform="$(_dns::detect_platform)"
    _info "Detected platform: $platform"
    _info "Preferred mode:    $mode_pref"

    if [ "$mode_pref" = "external" ]; then
        _dns::write_mode external "$DEFAULT_EXTERNAL_DOMAIN" "$DEFAULT_EXTERNAL_PROVIDER"
        _ok "External mode active. URLs: <port>.<project>.${DEFAULT_EXTERNAL_DOMAIN}"
        return 0
    fi

    # Unsupported platform is a DURABLE reason to live on sslip.io — there is
    # no host resolver we know how to wire up, so retrying buys nothing.
    # Settle into external mode calmly (no degraded retry marker).
    if [ "$platform" = "unsupported" ]; then
        _warn "Unsupported platform — cannot configure host resolver."
        if [ "$mode_pref" = "local" ]; then
            _fail "--local requested but this platform has no supported resolver setup."
            return 1
        fi
        _dns::write_mode external "$DEFAULT_EXTERNAL_DOMAIN" "$DEFAULT_EXTERNAL_PROVIDER"
        _ok "External mode active. URLs: <port>.<project>.${DEFAULT_EXTERNAL_DOMAIN}"
        return 0
    fi

    # Port 53 conflict is likewise DURABLE (another resolver owns the port);
    # external is the correct steady state, not a degraded one.
    if _dns::port_53_held_by_other; then
        _warn "Port 53 is in use by another process — local mode would conflict."
        if [ "$mode_pref" = "local" ]; then
            _fail "--local requested but port 53 is busy. Aborting."
            return 1
        fi
        _info "Falling back to external mode."
        _dns::write_mode external "$DEFAULT_EXTERNAL_DOMAIN" "$DEFAULT_EXTERNAL_PROVIDER"
        _ok "External mode active."
        return 0
    fi

    local setup_rc=0
    case "$platform" in
        macos)          _dns::install_macos          || setup_rc=$? ;;
        linux-resolved) _dns::install_linux_resolved || setup_rc=$? ;;
        linux-nm)       _dns::install_linux_nm       || setup_rc=$? ;;
        wsl2)           _dns::install_wsl2           || setup_rc=$? ;;
    esac

    if [ "$setup_rc" -ne 0 ]; then
        if [ "$mode_pref" = "local" ]; then
            _fail "--local requested but resolver setup failed."
            return 1
        fi
        # FIXABLE failure under auto mode → degraded state. Persist
        # preferred=local (intent) + active_domain=sslip (what works now), so
        # `boxa ports` advertises the resolvable sslip.io URLs instead of dead
        # `.test` ones, while self-heal still knows local was wanted. Loud +
        # non-zero so the user (and install.sh's action list) can't miss it.
        _dns::write_mode local "$DEFAULT_EXTERNAL_DOMAIN" "$DEFAULT_EXTERNAL_PROVIDER"
        _dns::degraded_banner
        return 1
    fi

    _dns::write_mode local "$BOXA_LOCAL_TLD" "$DEFAULT_EXTERNAL_PROVIDER"

    if _dns::resolver_works; then
        _ok "Local mode active. URLs: <port>.<project>.${BOXA_LOCAL_TLD}"
        return 0
    fi

    # *.test does not resolve. That is only a problem if boxa_dns is actually
    # running — if it is not (the expected state right after install, e.g. on
    # `boxa update` with no container up), resolution simply cannot work yet
    # and the _ok below already explains it starts with the next boxa. Don't
    # cry wolf with a WARN in that benign case (a WARN that fires in a normal
    # state trains the user to ignore WARNs).
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx boxa_dns; then
        _warn "Post-install verification failed: *.${BOXA_LOCAL_TLD} does not resolve to 127.0.0.1 even though boxa_dns is running. Check the host resolver drop-in and that nothing else holds 127.0.0.1:53."
    fi
    _ok "Local mode persisted. Resolver files are in place; dnsmasq will be started by the next 'boxa <project>'."
}

# --- CA install (HTTPS Phase 1) ----------------------------------------------

# Install the mkcert root CA into the host's native trust store. Runs after
# the DNS resolver setup so the user's one sudo/Touch ID prompt for HTTPS
# bootstrap shares a session with the DNS sudo prompts. Non-fatal: a missing
# binary or `mkcert -install` failure ends with a warning and lets DNS
# install report success on its own.
#
# Scope per ADR 0008 Phase 1: Linux/macOS-native trust stores only. On WSL2
# this configures the Linux-distro side only; Windows browser trust lands
# in Phase 6.
#
# Returns 0 only when the CA was actually installed (or was already installed
# and `mkcert -install` was a no-op). Returns 1 on missing binary or any
# `mkcert -install` failure — including the user cancelling sudo / Touch ID,
# which Phase 6's `_dns::enable_https` reads to refuse flipping `active=true`
# against an untrusted root. The `dns-install` action keeps swallowing this
# rc (HTTPS CA is best-effort for plain DNS install), so the stricter return
# only tightens the enable-https path.
_dns::install_ca() {
    # Auto-provision mkcert when missing. Users who installed boxa before
    # HTTPS Phase 1 shipped have no $HOME/.local/bin/mkcert — and `boxa
    # update` (their only update path) does a `git pull` + image rebuild
    # but never re-runs install.sh, so the binary never lands. Without
    # this hook the HTTPS upgrade prompt at the end of `boxa update`
    # would fail with "Run install.sh first", which is misleading: full
    # install.sh would also try to clone the repo + reset the /usr/local
    # symlink, both destructive for users on a custom boxa path.
    # scripts/install-mkcert.sh is the side-effect-scoped provisioner that
    # does ONLY the mkcert step.
    if ! _mkcert::resolve_bin >/dev/null 2>&1; then
        _info "No usable mkcert >= $BOXA_MKCERT_MIN_VERSION on PATH — provisioning the pinned version now..."
        if ! "$BOXA_DIR/scripts/install-mkcert.sh" --with-nss >/dev/null; then
            _warn "Failed to auto-install mkcert; HTTPS will not be available until this is resolved."
            return 1
        fi
        boxa::reset_mkcert_cache
        if ! _mkcert::resolve_bin >/dev/null 2>&1; then
            _warn "mkcert auto-install completed but no usable binary on PATH afterwards; HTTPS will not be available."
            return 1
        fi
    fi
    _info "Installing mkcert root CA (sudo / Touch ID may prompt)..."
    local caroot
    if ! caroot="$(seed_local_ca)"; then
        _warn "mkcert -install failed; HTTPS will not be available until this is resolved."
        return 1
    fi
    _ok "Root CA installed at $caroot."
    _dns::record_ca_install
    if [ "$(_dns::detect_platform)" = "wsl2" ]; then
        _info "WSL2: Windows-side browser trust will be installed in a later boxa release."
    fi
    # Explicit success return. The function's contract is "rc=0 on a fully
    # successful install"; without this, the rc would silently fold in
    # whatever the final `if` evaluates to, which today happens to land
    # on 0 (bash returns 0 from an `if` whose test fails and has no else),
    # but adding any statement after this block — or flipping the test —
    # would silently break the gate in `_dns::enable_https`.
    return 0
}

# Persist the CA install metadata to ~/.config/boxa/https.conf so later
# phases — Traefik bootstrap (4), cert lifecycle (3), dns-status (8) — can
# detect CA churn and report install state without re-running mkcert. We do
# NOT flip `active=true` here: that decision belongs to the user-visible
# Phase 6 upgrade prompt. Phase 1's job is only to capture provenance.
#
# Best-effort: failures to read fingerprint/version warn and continue. A
# missing https.conf write would block the entire dns-install command for
# what is, at this stage, purely diagnostic state.
_dns::record_ca_install() {
    local fingerprint version installed_at platform_tag
    if ! fingerprint="$(_mkcert::ca_fingerprint 2>/dev/null)" || [ -z "$fingerprint" ]; then
        _warn "Could not read rootCA fingerprint; https.conf CA metadata will be incomplete."
        fingerprint=""
    fi
    if ! version="$(_mkcert::version 2>/dev/null)" || [ -z "$version" ]; then
        version=""
    fi
    installed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    platform_tag="$(_dns::ca_platform_tag)"

    boxa::write_https_field ca_fingerprint  "$fingerprint"  || _warn "Failed writing ca_fingerprint to https.conf."
    boxa::write_https_field mkcert_version  "$version"      || _warn "Failed writing mkcert_version to https.conf."
    boxa::write_https_field ca_installed_at "$installed_at" || _warn "Failed writing ca_installed_at to https.conf."
    if [ -n "$platform_tag" ]; then
        boxa::add_ca_installed_platform "$platform_tag" || _warn "Failed updating ca_installed_platforms in https.conf."
    fi
}

# Map _dns::detect_platform output to the lib/https.sh trust-store taxonomy
# (linux | macos | windows). WSL2 maps to `linux` because phase 1's mkcert
# -install only writes the WSL2-distro's Linux trust store; the Windows-side
# certutil pass that earns the `windows` tag lands in phase 6.
_dns::ca_platform_tag() {
    case "$(_dns::detect_platform)" in
        macos)                        printf 'macos' ;;
        linux-resolved|linux-nm|wsl2) printf 'linux' ;;
        *)                            printf '' ;;
    esac
}

# --- CA purge (Phase 7) ------------------------------------------------------

# Remove the mkcert root CA from the native trust store via `mkcert -uninstall`.
# Inverse of `_dns::install_ca` / `seed_local_ca`. Best-effort: a missing
# binary or a sudo / Touch ID decline returns 1 but never aborts the
# enclosing purge — `_dns::purge_ca` keeps going so https.conf + the CAROOT
# directory are still cleaned, and the user can re-run with sudo cached.
_dns::purge_ca_native() {
    if ! _mkcert::resolve_bin >/dev/null 2>&1; then
        _warn "mkcert binary unavailable — skipping native trust-store uninstall."
        return 1
    fi
    local bin
    bin="$(_mkcert::resolve_bin)"
    _info "Running 'mkcert -uninstall' (sudo / Touch ID may prompt)..."
    if ! "$bin" -uninstall >&2; then
        _warn "mkcert -uninstall failed — native trust store may still contain a boxa CA."
        return 1
    fi
    return 0
}

# Inverse of `_dns::install_windows_ca` for the WSL2 path. One elevated
# PowerShell child handles both:
#   1. Windows LocalMachine\Root store: find every cert whose Subject matches
#      `mkcert development CA *` and remove it via `certutil.exe -delstore
#      Root <thumbprint>`. We look the thumbprint up on the Windows side
#      rather than passing https.conf's fingerprint in because certutil
#      keys off the cert's SHA-1 thumbprint while https.conf stores the
#      SHA-256 of rootCA.pem; the two are not interchangeable and there is
#      no portable WSL2-side tool that emits a SHA-1 of the in-store cert.
#   2. Firefox policies.json: merge-aware removal — drop ONLY the
#      ImportEnterpriseRoots key we set. Per Phase 6 risk register, an
#      org-managed `Certificates` branch with other keys (e.g. `Install`)
#      stays intact; we only collapse the branch (and then the file) when
#      it becomes empty as a result of our removal. This guarantees boxa
#      uninstall never wipes a corporate Firefox policy.
#
# Returns 0 when the elevated child exits cleanly. Non-zero on UAC decline,
# missing tooling, or any certutil failure.
_dns::purge_ca_windows() {
    if ! command -v powershell.exe >/dev/null 2>&1; then
        _warn "powershell.exe not found — cannot remove CA from Windows trust store."
        return 1
    fi
    if ! command -v iconv >/dev/null 2>&1 || ! command -v base64 >/dev/null 2>&1; then
        _warn "iconv / base64 missing — cannot encode PowerShell command for Windows CA purge."
        return 1
    fi

    local inner
    inner="$(cat <<'PS_INNER'
$ErrorActionPreference = 'Continue'
$hadFailure = $false
try {
    $certs = Get-ChildItem -Path Cert:\LocalMachine\Root -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -like '*mkcert development CA*' }
    foreach ($c in @($certs)) {
        & certutil.exe -delstore Root $c.Thumbprint | Out-Null
        if ($LASTEXITCODE -ne 0) { $hadFailure = $true }
    }
} catch {
    $hadFailure = $true
}
try {
    $pjson = 'C:\Program Files\Mozilla Firefox\distribution\policies.json'
    if (Test-Path $pjson) {
        $existing = $null
        try { $existing = Get-Content $pjson -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $existing = $null }
        if ($null -ne $existing -and $existing.policies -and $existing.policies.PSObject.Properties.Match('Certificates').Count) {
            if ($existing.policies.Certificates.PSObject.Properties.Match('ImportEnterpriseRoots').Count) {
                $existing.policies.Certificates.PSObject.Properties.Remove('ImportEnterpriseRoots')
            }
            if (($existing.policies.Certificates.PSObject.Properties | Measure-Object).Count -eq 0) {
                $existing.policies.PSObject.Properties.Remove('Certificates')
            }
            if (($existing.policies.PSObject.Properties | Measure-Object).Count -eq 0) {
                Remove-Item -Path $pjson -Force
            } else {
                ($existing | ConvertTo-Json -Depth 10) | Set-Content -Path $pjson -Encoding UTF8
            }
        }
    }
} catch {
    # Firefox policy merge is best-effort.
}
if ($hadFailure) { exit 2 }
exit 0
PS_INNER
)"

    local encoded_inner
    encoded_inner="$(printf '%s' "$inner" | iconv -t UTF-16LE | base64 -w0)"

    # Outer wrapper does the Start-Process -Verb RunAs (UAC trigger) and
    # propagates the elevated child's exit code. Same shape as
    # `_dns::install_windows_ca` — `-PassThru` is the only way to observe
    # ExitCode through Start-Process.
    local outer
    outer="try { \$p = Start-Process powershell -Verb RunAs -Wait -PassThru -ArgumentList '-NoProfile','-EncodedCommand','${encoded_inner}'; exit \$p.ExitCode } catch { exit 1 }"
    local encoded_outer
    encoded_outer="$(printf '%s' "$outer" | iconv -t UTF-16LE | base64 -w0)"

    _info "Removing root CA from Windows trust store (UAC will prompt)..."
    local rc=0
    powershell.exe -NoProfile -EncodedCommand "$encoded_outer" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
        _warn "Windows CA removal failed or UAC declined (exit $rc) — browsers may still trust boxa certs until manual cleanup."
        return 1
    fi
    return 0
}

# Orchestrate the full CA purge. Inverse of `_dns::enable_https`'s install
# pass. Each sub-step is independently best-effort: a failure in one does
# not block the next, because partial cleanup is strictly better than
# leaving every artifact behind. We do, however, preserve order:
#
#   1. mkcert -uninstall on the host's native trust store (uses CAROOT to
#      identify which CA to remove — must run BEFORE we delete CAROOT).
#   2. (WSL2 only) Windows-side certutil + Firefox policy merge — uses the
#      cert Subject to find what to delete, so it is independent of CAROOT.
#   3. Delete ~/.config/boxa/https.conf — drops the cached fingerprint
#      and active flag, so the next `--enable-https` re-records everything
#      from a fresh `mkcert -install`.
#   4. Delete the mkcert CAROOT directory (rootCA.pem + rootCA-key.pem).
#      This is the paranoid step — opt-out via BOXA_PURGE_MKCERT_DIR=0
#      for users who share mkcert with non-boxa projects. Default is
#      "yes, nuke it" because the user just asked for `--purge-ca`.
_dns::purge_ca() {
    local platform
    platform="$(_dns::detect_platform)"
    _info "Purging mkcert root CA (platform: $platform)..."

    local rc=0
    case "$platform" in
        macos|linux-resolved|linux-nm)
            _dns::purge_ca_native || rc=$?
            ;;
        wsl2)
            # Linux-side first (uses CAROOT), then Windows-side (UAC).
            _dns::purge_ca_native  || rc=$?
            _dns::purge_ca_windows || rc=$?
            ;;
        *)
            _warn "Unsupported platform — cannot purge CA programmatically."
            rc=1
            ;;
    esac

    # Capture CAROOT BEFORE removing https.conf — the path itself comes
    # from `mkcert -CAROOT`, not from https.conf, but doing the capture
    # first keeps the ordering intuitive: "compute, then delete".
    local caroot=""
    caroot="$(_mkcert::caroot 2>/dev/null || true)"

    local https_conf="${BOXA_HTTPS_CONF:-$HOME/.config/boxa/https.conf}"
    if [ -f "$https_conf" ]; then
        rm -f "$https_conf"
        echo "Removed $https_conf"
    fi
    boxa::reset_https_cache

    if [ "${BOXA_PURGE_MKCERT_DIR:-1}" = "1" ]; then
        if [ -n "$caroot" ] && [ -d "$caroot" ]; then
            rm -rf "$caroot"
            echo "Removed $caroot"
        fi
    fi

    if [ "$rc" -eq 0 ]; then
        _ok "CA purge complete."
    else
        _warn "CA purge finished with errors — review warnings above."
    fi
    return "$rc"
}

# --- HTTPS enable / disable (Phase 6) ----------------------------------------

# Install the mkcert root CA into the Windows trust store from inside a WSL2
# distro. One elevated PowerShell child handles both the Windows Root store
# (`certutil.exe -addstore -f Root`) and the Firefox enterprise-roots policy
# (`policies.json` with `Certificates.ImportEnterpriseRoots=true`), so the
# user only sees a single UAC prompt across both browsers' trust paths.
#
# The Firefox `policies.json` is merged, not overwritten: an existing
# org-managed policy keeps every other key it already had. We add the
# Certificates branch (or set `ImportEnterpriseRoots=true` inside an existing
# one) and leave the rest intact — per the Phase 6 risk-register entry.
#
# Return codes:
#   0  Success (Windows Root store accepted the cert; Firefox merge is
#      best-effort and does not gate success).
#   2  User declined UAC. Surfaced as a distinct rc so `_dns::enable_https`
#      can persist `optout=true` for this single explicit-decline case
#      while transient failures (rc=1) still let the next `boxa update`
#      offer the prompt again.
#   1  Any other failure: missing powershell.exe / wslpath / iconv / base64,
#      unreachable Windows %TEMP%, certutil rejection (corporate policy
#      block), Start-Process error, staging copy failure, etc. — all
#      treated as transient/setup conditions by the caller.
_dns::install_windows_ca() {
    if ! command -v powershell.exe >/dev/null 2>&1; then
        _warn "powershell.exe not found — cannot install CA into Windows trust store."
        return 1
    fi
    if ! command -v iconv >/dev/null 2>&1 || ! command -v base64 >/dev/null 2>&1; then
        _warn "iconv / base64 missing — cannot encode PowerShell command for Windows CA install."
        return 1
    fi
    if ! command -v wslpath >/dev/null 2>&1; then
        _warn "wslpath missing — cannot translate WSL2 path to Windows path for CA copy."
        return 1
    fi

    local caroot
    if ! caroot="$(_mkcert::caroot)" || [ -z "$caroot" ] || [ ! -f "$caroot/rootCA.pem" ]; then
        _warn "mkcert CAROOT or rootCA.pem missing — run 'boxa dns-install' first."
        return 1
    fi

    # Stage rootCA.pem into Windows %TEMP%. Elevated certutil only needs read
    # access; placing it under the calling user's TEMP keeps cleanup trivial
    # and side-steps writability quirks of C:\Windows\Temp on locked-down
    # corporate machines.
    local win_temp_raw win_temp_linux
    win_temp_raw="$(cmd.exe /c 'echo %TEMP%' 2>/dev/null | tr -d '\r\n')"
    if [ -z "$win_temp_raw" ]; then
        _warn "Could not read Windows %TEMP% via cmd.exe — cannot stage CA file."
        return 1
    fi
    if ! win_temp_linux="$(wslpath -u "$win_temp_raw" 2>/dev/null)" \
        || [ -z "$win_temp_linux" ] || [ ! -d "$win_temp_linux" ]; then
        _warn "Windows %TEMP% ($win_temp_raw) is not reachable from WSL2 — cannot stage CA."
        return 1
    fi
    local staged_linux="$win_temp_linux/boxa-rootCA.pem"
    if ! cp "$caroot/rootCA.pem" "$staged_linux"; then
        _warn "Failed to copy rootCA.pem to $staged_linux."
        return 1
    fi
    local staged_win
    staged_win="$(wslpath -w "$staged_linux" 2>/dev/null)"
    if [ -z "$staged_win" ]; then
        _warn "wslpath failed to compute Windows path for $staged_linux."
        rm -f "$staged_linux"
        return 1
    fi

    # Inner script runs elevated. Single-quoted PowerShell literals carry the
    # path verbatim, so we only need to make sure $staged_win contains no
    # single quotes — Windows TEMP paths never do.
    local inner
    inner="$(cat <<PS_INNER
\$ErrorActionPreference = 'Stop'
try {
    & certutil.exe -addstore -f Root '${staged_win}' | Out-Null
    if (\$LASTEXITCODE -ne 0) { exit 2 }
} catch {
    exit 2
}
try {
    \$ffDir = 'C:\\Program Files\\Mozilla Firefox'
    if (Test-Path \$ffDir) {
        \$distDir = Join-Path \$ffDir 'distribution'
        New-Item -Force -ItemType Directory -Path \$distDir | Out-Null
        \$pjson = Join-Path \$distDir 'policies.json'
        \$existing = \$null
        if (Test-Path \$pjson) {
            try { \$existing = Get-Content \$pjson -Raw -Encoding UTF8 | ConvertFrom-Json } catch { \$existing = \$null }
        }
        if (\$null -eq \$existing) { \$existing = New-Object PSObject }
        if (-not (\$existing.PSObject.Properties.Match('policies').Count)) {
            \$existing | Add-Member -NotePropertyName policies -NotePropertyValue (New-Object PSObject) -Force
        }
        if (-not (\$existing.policies.PSObject.Properties.Match('Certificates').Count)) {
            \$existing.policies | Add-Member -NotePropertyName Certificates -NotePropertyValue (New-Object PSObject) -Force
        }
        if (\$existing.policies.Certificates.PSObject.Properties.Match('ImportEnterpriseRoots').Count) {
            \$existing.policies.Certificates.ImportEnterpriseRoots = \$true
        } else {
            \$existing.policies.Certificates | Add-Member -NotePropertyName ImportEnterpriseRoots -NotePropertyValue \$true -Force
        }
        (\$existing | ConvertTo-Json -Depth 10) | Set-Content -Path \$pjson -Encoding UTF8
    }
} catch {
    # Firefox policy merge is best-effort.
}
exit 0
PS_INNER
)"

    local encoded_inner
    encoded_inner="$(printf '%s' "$inner" | iconv -t UTF-16LE | base64 -w0)"

    # Outer wrapper does the Start-Process -Verb RunAs (the UAC trigger) and
    # propagates the elevated child's exit code so this function can see
    # whether certutil actually succeeded. `-PassThru` is the only way to
    # observe ExitCode; without it Start-Process returns nothing.
    #
    # We special-case the UAC-cancel signal: Start-Process throws
    # System.ComponentModel.Win32Exception with NativeErrorCode 1223
    # ("ERROR_CANCELLED" — the operation was canceled by the user) when
    # the user clicks "No" on the UAC dialog. Surfacing that as a
    # distinct exit code (3 from PowerShell, mapped to rc=2 in this
    # function) lets the caller treat it as an explicit user decline
    # and persist `optout=true`, while every other Start-Process error
    # path (missing exe, COM init failure, etc.) folds into rc=1 and
    # leaves optout untouched so the next update offers the prompt
    # again.
    #
    # `-ErrorAction Stop` is load-bearing: by default Start-Process emits
    # the UAC-cancel as a NON-terminating error, which leaves the typed
    # `catch [Win32Exception]` block dormant and exits the try-block
    # without ever hitting our exit 3. Forcing terminating-error mode
    # routes the cancel through the catch as documented.
    local outer
    outer="try { \$p = Start-Process powershell -Verb RunAs -Wait -PassThru -ErrorAction Stop -ArgumentList '-NoProfile','-EncodedCommand','${encoded_inner}'; exit \$p.ExitCode } catch [System.ComponentModel.Win32Exception] { if (\$_.Exception.NativeErrorCode -eq 1223) { exit 3 } exit 1 } catch { exit 1 }"
    local encoded_outer
    encoded_outer="$(printf '%s' "$outer" | iconv -t UTF-16LE | base64 -w0)"

    _info "Installing root CA into Windows trust store (UAC will prompt)..."
    local rc=0
    powershell.exe -NoProfile -EncodedCommand "$encoded_outer" >/dev/null 2>&1 || rc=$?
    rm -f "$staged_linux"
    case "$rc" in
        0)  return 0 ;;
        3)
            _warn "Windows CA install canceled at UAC prompt — boxa will record opt-out and stop asking on future updates."
            return 2
            ;;
        *)
            _warn "Windows CA install failed (exit $rc) — browsers on Windows will not trust boxa certs. Next 'boxa update' will retry."
            return 1
            ;;
    esac
}

# Orchestrate the full HTTPS enable flow:
#   1. Make sure mkcert -install has run on the host's native trust store
#      (Linux NSS, macOS Keychain, or WSL2-distro NSS — phase 1's path).
#      _dns::install_ca auto-provisions the mkcert binary itself when the
#      pinned version isn't on disk yet, so users who installed boxa
#      before HTTPS Phase 1 shipped don't have to re-run install.sh.
#   2. On WSL2, additionally install the CA into the Windows side (certutil
#      + Firefox policy) — the only step that fires UAC.
#   3. Flip https.conf `active=true` + `optout=false` and tag the platforms.
#
# Failure handling distinguishes TRANSIENT issues from EXPLICIT USER DECLINE:
#   - Transient (download error, native sudo decline, hash mismatch, etc.):
#     return 1 and leave `optout` untouched so the next `boxa update`
#     still offers the prompt. The previous "always set optout=true on
#     any failure" behavior wedged users into HTTP-only the moment a
#     missing mkcert tripped the gate — they would never see the prompt
#     again even after the underlying problem was fixed.
#   - Explicit decline (WSL2 Windows UAC cancel): set `optout=true` per
#     ADR 0008 § risk table. UAC is the only step where a user can
#     unambiguously say "no, I do not want HTTPS"; everything else is
#     plumbing that may succeed on a retry.
_dns::enable_https() {
    _info "Enabling HTTPS for boxa..."

    # _dns::install_ca is idempotent and self-provisioning: it auto-downloads
    # the pinned mkcert when missing (via scripts/install-mkcert.sh) and a
    # second `mkcert -install` on a host whose trust store already has our
    # CA is a no-op. A failed CA install MUST block flipping `active=true`:
    # every advertised `https://...` URL would otherwise serve a cert
    # signed by a root the host does not trust.
    if ! _dns::install_ca; then
        return 1
    fi

    local platform
    platform="$(_dns::detect_platform)"
    if [ "$platform" = "wsl2" ]; then
        _dns::install_windows_ca
        local wca_rc=$?
        if [ "$wca_rc" -ne 0 ]; then
            # rc=2 is the dedicated UAC-cancel signal — the only branch
            # where the user has unambiguously said "no, do not enable
            # HTTPS". Every other non-zero rc is environmental (missing
            # tooling, certutil rejection, COM init failure), so we leave
            # `optout` untouched and let the next `boxa update` retry.
            if [ "$wca_rc" -eq 2 ]; then
                boxa::write_https_field optout true || true
            fi
            return 1
        fi
        boxa::add_ca_installed_platform windows \
            || _warn "Failed updating ca_installed_platforms with 'windows'."
    fi

    if ! boxa::write_https_field active true; then
        _warn "Failed flipping https.conf active=true."
        return 1
    fi
    if ! boxa::write_https_field optout false; then
        _warn "Failed clearing https.conf optout flag."
    fi
    _ok "HTTPS enabled. Per-project leaf certs land on the next 'boxa <project>'."
}

# Counterpart to enable: flip active=false in https.conf. The CA stays in
# the trust stores — uninstall is the place that pulls it. We deliberately
# do NOT touch `optout` here: `--disable-https` is "for now"; `optout` is
# the long-lived "do not ask me again" signal owned by the Phase 6 update
# prompt.
#
# This function is intentionally pure — it touches only https.conf and
# does NOT recreate Traefik or rewrite route YAMLs. Container + route
# orchestration lives in docker-run.sh's `_boxa::run_https_downgrade`,
# which calls this function (with `_BOXA_HTTPS_FLIP_ONLY=1`) after the
# orchestration has been entered. A direct `scripts/dns-install.sh
# --disable-https` invocation is re-exec'd through the docker-run.sh
# wrapper by the main dispatcher below, so the half-disabled state
# (active=false in config but Traefik still HTTPS, route YAMLs still
# websecure) cannot leak out to the user regardless of entry point.
_dns::disable_https() {
    if ! boxa::write_https_field active false; then
        _fail "Failed setting https.conf active=false."
        return 1
    fi
    _ok "HTTPS marked inactive in https.conf."
}

# --- Status ------------------------------------------------------------------

_dns::status() {
    local platform
    platform="$(_dns::detect_platform)"
    echo "Platform:           $platform"
    echo "Active domain:      $(boxa::route_domain)"
    echo "External provider:  $(boxa::external_provider)"
    if [ -f "$DNS_CONF_FILE" ]; then
        echo "dns.conf:           $DNS_CONF_FILE (present)"
    else
        echo "dns.conf:           $DNS_CONF_FILE (missing — defaults in effect)"
    fi
    case "$platform" in
        macos)
            local r="/etc/resolver/$BOXA_LOCAL_TLD"
            echo "Resolver file:      $r $([ -f "$r" ] && echo "(present)" || echo "(missing)")"
            ;;
        linux-resolved|wsl2)
            local d="/etc/systemd/resolved.conf.d/boxa.conf"
            echo "Resolved drop-in:   $d $([ -f "$d" ] && echo "(present)" || echo "(missing)")"
            ;;
        linux-nm)
            local d="/etc/NetworkManager/dnsmasq.d/boxa.conf"
            echo "NM drop-in:         $d $([ -f "$d" ] && echo "(present)" || echo "(missing)")"
            ;;
    esac
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx boxa_dns; then
        echo "Resolver container: boxa_dns (running)"
    elif docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx boxa_dns; then
        echo "Resolver container: boxa_dns (stopped — starts with next boxa)"
    else
        echo "Resolver container: boxa_dns (not created — starts with next boxa)"
    fi
    echo
    if _dns::resolver_works; then
        _ok "Verification: *.${BOXA_LOCAL_TLD} resolves to 127.0.0.1."
    elif [ "$(boxa::route_domain)" = "$BOXA_LOCAL_TLD" ]; then
        _warn "Verification: *.${BOXA_LOCAL_TLD} does NOT currently resolve to 127.0.0.1. Ensure boxa_dns is running ('boxa <project>')."
    else
        echo "Verification: skipped (external mode active)."
    fi

    _dns::status_https
}

# Append the HTTPS section to `_dns::status` output: high-level state from
# https.conf plus a project-cert inventory (count + nearest expiry parsed
# from meta files). Best-effort: a cert meta with an unreadable `expires_at`
# still counts toward the project total, it just sits out of the nearest-
# expiry computation. Empty fields are surfaced as `(not installed)` /
# `(none)` rather than blanks so an uninitialised state reads cleanly.
_dns::status_https() {
    local active="false" optout="false"
    boxa::https_active && active="true"
    boxa::https_optout && optout="true"

    local fingerprint platforms
    fingerprint="$(boxa::ca_fingerprint)"
    platforms="$(boxa::ca_installed_platforms)"

    local ca_display="(not installed)"
    [ -n "$fingerprint" ] && ca_display="sha256:${fingerprint}"

    local trust_display="(none)"
    [ -n "$platforms" ] && trust_display="$platforms"

    local count=0 nearest_epoch=""
    if [ -d "$BOXA_CERTS_DIR" ]; then
        local meta_path
        for meta_path in "$BOXA_CERTS_DIR"/*.meta; do
            [ -f "$meta_path" ] || continue
            count=$((count + 1))
            local m_issued_at m_expires_at m_ca_fingerprint
            local m_mkcert_version m_external_provider m_sans
            _cert::read_meta "$meta_path" m
            # Only m_expires_at participates in the aggregation; the other
            # fields are read for the side-effect (they leak as locals from
            # the eval inside _cert::read_meta) — silence the unused warning.
            : "${m_issued_at-}" "${m_ca_fingerprint-}" "${m_mkcert_version-}" \
                "${m_external_provider-}" "${m_sans-}"
            if [ -n "$m_expires_at" ] && [ "$m_expires_at" -gt 0 ] 2>/dev/null; then
                if [ -z "$nearest_epoch" ] || [ "$m_expires_at" -lt "$nearest_epoch" ]; then
                    nearest_epoch="$m_expires_at"
                fi
            fi
        done
    fi

    local certs_display="$count"
    if [ "$count" -gt 0 ] && [ -n "$nearest_epoch" ]; then
        # GNU date understands `-d "@<epoch>"`; BSD date (macOS) needs
        # `-r <epoch>`. Try both so dns-status reads correctly on either
        # host. If neither lands a date, fall back to the bare count —
        # we never want a missing tool to produce a noisy traceback in
        # the middle of a status command.
        local nearest_date now days
        nearest_date="$(date -u -d "@$nearest_epoch" +%Y-%m-%d 2>/dev/null \
                       || date -u -r "$nearest_epoch" +%Y-%m-%d 2>/dev/null \
                       || true)"
        now="$(date +%s)"
        days=$(( (nearest_epoch - now) / 86400 ))
        if [ -n "$nearest_date" ]; then
            certs_display="$count (nearest expiry: $nearest_date, in $days days)"
        fi
    fi

    echo
    echo "HTTPS state:"
    printf '  %-15s %s\n' "active:"        "$active"
    printf '  %-15s %s\n' "CA:"            "$ca_display"
    printf '  %-15s %s\n' "trust stores:"  "$trust_display"
    printf '  %-15s %s\n' "project certs:" "$certs_display"
    printf '  %-15s %s\n' "optout:"        "$optout"
}

# --- Uninstall ---------------------------------------------------------------

_dns::uninstall() {
    local platform
    platform="$(_dns::detect_platform)"
    _info "Uninstalling boxa DNS resolver config (platform: $platform)..."

    case "$platform" in
        macos)
            local r="/etc/resolver/$BOXA_LOCAL_TLD"
            if [ -f "$r" ]; then
                if _dns::sudo_available; then
                    sudo rm -f "$r"
                    echo "Removed $r"
                else
                    _warn "sudo not available — cannot remove $r"
                fi
            fi
            ;;
        linux-resolved)
            _dns::uninstall_resolved_drop_in
            ;;
        linux-nm)
            local d="/etc/NetworkManager/dnsmasq.d/boxa.conf"
            if [ -f "$d" ]; then
                if _dns::sudo_available; then
                    sudo rm -f "$d"
                    echo "Removed $d"
                    sudo systemctl reload NetworkManager 2>/dev/null \
                        || _warn "NetworkManager reload failed"
                else
                    _warn "sudo not available — cannot remove $d"
                fi
            fi
            ;;
        wsl2)
            _dns::uninstall_resolved_drop_in
            _dns::uninstall_wsl2_nrpt
            ;;
    esac

    if [ -f "$DNS_CONF_FILE" ]; then
        rm -f "$DNS_CONF_FILE"
        echo "Removed $DNS_CONF_FILE"
    fi
    boxa::reset_dns_cache
    _ok "Uninstall complete."
}

_dns::uninstall_resolved_drop_in() {
    local d="/etc/systemd/resolved.conf.d/boxa.conf"
    [ -f "$d" ] || return 0
    if ! _dns::sudo_available; then
        _warn "sudo not available — cannot remove $d"
        return 0
    fi
    sudo rm -f "$d"
    echo "Removed $d"
    sudo systemctl restart systemd-resolved 2>/dev/null \
        || _warn "systemd-resolved restart failed"
}

_dns::uninstall_wsl2_nrpt() {
    command -v powershell.exe >/dev/null 2>&1 || return 0
    if ! command -v iconv >/dev/null 2>&1 || ! command -v base64 >/dev/null 2>&1; then
        _warn "iconv / base64 missing — cannot remove Windows NRPT rule programmatically."
        return 0
    fi
    local tld="$BOXA_LOCAL_TLD"
    local ps_cmd
    ps_cmd="Get-DnsClientNrptRule -ErrorAction SilentlyContinue | Where-Object { \$_.Namespace -eq '.${tld}' -and \$_.NameServers -contains '127.0.0.1' } | Remove-DnsClientNrptRule -Force -ErrorAction SilentlyContinue"
    local encoded
    encoded="$(printf '%s' "$ps_cmd" | iconv -t UTF-16LE | base64 -w0)"
    _info "Removing Windows NRPT rule (UAC will prompt)..."
    powershell.exe -NoProfile -Command \
        "Start-Process powershell -Verb RunAs -Wait -ArgumentList '-NoProfile','-EncodedCommand','$encoded'" \
        >/dev/null 2>&1 \
        || _warn "Windows NRPT removal failed or UAC declined."
}

# --- Argument dispatch -------------------------------------------------------

print_warnings() {
    [ "${#WARNINGS[@]}" -eq 0 ] && return 0
    echo
    printf "${RED}==> dns-install finished with %d warning(s):${NC}\n" "${#WARNINGS[@]}"
    local w
    for w in "${WARNINGS[@]}"; do
        printf "    ${YELLOW}- %s${NC}\n" "$w"
    done
}

main() {
    local action="install"
    local mode_pref="auto"
    while [ "$#" -gt 0 ]; do
        case "$1" in
            install|status|uninstall|purge-ca) action="$1" ;;
            --local)          mode_pref="local" ;;
            --external)       mode_pref="external" ;;
            --auto)           mode_pref="auto" ;;
            --status)         action="status" ;;
            --uninstall)      action="uninstall" ;;
            --purge-ca)       action="purge-ca" ;;
            --enable-https)   action="enable-https" ;;
            --disable-https)  action="disable-https" ;;
            -h|--help)        usage; exit 0 ;;
            *) _fail "Unknown argument: $1"; usage >&2; exit 2 ;;
        esac
        shift
    done

    local rc=0
    case "$action" in
        install)
            # Prime one sudo session up front so the resolver write and the
            # CA install below share a single auth moment (see _dns::prime_sudo).
            _dns::prime_sudo
            _dns::install "$mode_pref" || rc=$?
            # CA install is intentionally best-effort for `dns-install` —
            # DNS resolver setup can succeed on a host where mkcert is missing
            # or where the user cancels sudo / Touch ID. Tightening
            # _dns::install_ca to return 1 (so --enable-https can refuse to
            # flip active=true on a failed trust install) means set -e would
            # otherwise kill the script here before print_warnings runs and
            # turn a non-fatal CA hiccup into an apparent dns-install failure.
            _dns::install_ca || true
            ;;
        status)         _dns::status        || rc=$? ;;
        uninstall)      _dns::uninstall     || rc=$? ;;
        purge-ca)       _dns::purge_ca      || rc=$? ;;
        enable-https|disable-https)
            # `--enable-https` and `--disable-https` only flip https.conf
            # state and (for enable) install the CA — they deliberately
            # do NOT touch Traefik or route YAMLs. The full lifecycle is
            # owned by `_boxa::run_https_upgrade` / `_boxa::run_https_downgrade`
            # in docker-run.sh, which the `boxa dns-install --enable-https`
            # wrapper invokes. A direct call to this script with the same
            # flag would otherwise leave the system in a half-flipped state
            # (config says one thing, route YAMLs + Traefik say the other),
            # so when invoked outside the wrapper we re-exec through it
            # and let the orchestration drive the full sequence. The
            # wrapper calls us back with `_BOXA_HTTPS_FLIP_ONLY=1` set,
            # which breaks the otherwise-infinite recursion and signals
            # us to do the bare state flip the orchestration is delegating.
            if [ "${_BOXA_HTTPS_FLIP_ONLY:-0}" != "1" ]; then
                exec "$BOXA_DIR/docker-run.sh" dns-install "--$action"
            fi
            case "$action" in
                enable-https)  _dns::enable_https  || rc=$? ;;
                disable-https) _dns::disable_https || rc=$? ;;
            esac
            ;;
    esac
    [ "$action" != "status" ] && print_warnings
    return "$rc"
}

# Auto-run only when executed directly. Sourcing the script (tests) exposes the
# `_dns::*` functions without firing main and its side effects.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
