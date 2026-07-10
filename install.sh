#!/bin/bash
set -euo pipefail
trap 'printf "\033[1;31m==> ERROR: Script failed at line %s (exit code %s)\033[0m\n" "$LINENO" "$?"' ERR

# =============================================================================
# Boxa Installer
# =============================================================================
# Installs prerequisites and sets up boxa development environment.
#
# Recommended usage:
#   curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/IVIJL/boxa/main/install.sh -o install.sh
#   less install.sh
#   bash install.sh
#
# One-liner:
#   curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/IVIJL/boxa/main/install.sh | bash -s -- --yes
# =============================================================================

# Brand constants. install.sh is a standalone bootstrap (curl'd and run BEFORE
# the repo exists), so it cannot source lib/brand.sh for the clone — it carries
# its own copy of the brand name and derives the repo slug / paths from it. The
# canonical source of truth once the checkout exists is lib/brand.sh
# (CLI_NAME, BRAND_REPO_SLUG, …); keep these in lockstep with it.
CLI_NAME="boxa"
BOXA_REPO_SLUG="IVIJL/${CLI_NAME}"
BOXA_REPO="https://github.com/${BOXA_REPO_SLUG}.git"
BOXA_DIR="${HOME}/.local/share/${CLI_NAME}"
SYMLINK_PATH="/usr/local/bin/${CLI_NAME}"

# mkcert version printed in the install summary. The authoritative pin lives
# in scripts/install-mkcert.sh (which also holds the SHA-256 table); this
# constant is display-only. A drift here would just print a stale version
# string — the version gate at runtime is owned by lib/mkcert.sh's
# _mkcert::probe and stays correct regardless.
MKCERT_VERSION="1.4.4"

AUTO_YES=false
OS=""
PM=""
NEED_RELOGIN=false
# How the container fleet will authenticate to Claude, decided in
# setup_claude_token and read by print_summary's Next steps:
#   have-token  — token file already present (auth done)
#   macos-token — macOS without token (only `boxa claude-token` works)
#   auto        — non-macOS, host creds / claude present (inherited automatically)
#   export      — nothing to inherit; user must export ANTHROPIC_API_KEY
CLAUDE_AUTH=""

# Tracking what was done
declare -a INSTALLED=()
declare -a SKIPPED=()
declare -a CONFIGURED=()
# Manual GUI steps macOS won't let us automate — surfaced as the very last,
# most prominent block of output so they aren't lost mid-stream.
declare -a ACTION_REQUIRED=()

# --- Helpers -----------------------------------------------------------------

msg()     { printf '  %s\n' "$*"; }
info()    { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
success() { printf '\033[1;32m==> %s\033[0m\n' "$*"; }
warn()    { printf '\033[1;33m==> WARNING: %s\033[0m\n' "$*"; }
error()   { printf '\033[1;31m==> ERROR: %s\033[0m\n' "$*"; exit 1; }

confirm() {
    if $AUTO_YES; then return 0; fi
    printf '\033[1;33m==> %s [y/N] \033[0m' "$1"
    read -r answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

has() { command -v "$1" &>/dev/null; }

is_wsl2() { grep -qi microsoft /proc/version 2>/dev/null; }

# Docker state after check_docker(): "running", "installed", "desktop", "missing"
DOCKER_STATE="missing"

# --- Argument parsing --------------------------------------------------------

usage() {
    cat <<'EOF'
Usage: install.sh [OPTIONS]

Install boxa and its prerequisites.

Options:
  --yes, -y    Skip all confirmation prompts (required when piped)
  --help, -h   Show this help message

What this script does:
  1. Installs git, keychain, and xhost (if missing; xhost = native Linux only)
  2. Configures SSH agent via keychain (no key scanning)
  3. Adds AddKeysToAgent to ~/.ssh/config
  4. Clones boxa to ~/.local/share/boxa
  5. Installs mkcert and sets up the .test host resolver + mkcert CA (sudo / Touch ID)
  6. Checks Docker availability (never installs automatically)
  7. Installs 'boxa' command to /usr/local/bin

This script NEVER accesses or scans your private SSH keys.
EOF
    exit 0
}

for arg in "$@"; do
    case "$arg" in
        --yes|-y) AUTO_YES=true ;;
        --help|-h) usage ;;
        *) error "Unknown option: $arg (use --help for usage)" ;;
    esac
done

# --- Pipe detection ----------------------------------------------------------

if [ ! -t 0 ] && ! $AUTO_YES; then
    cat <<'EOF'

  This script is being piped but --yes was not passed.

  For safety, please either:

  1. Download and review first (recommended):
     curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/IVIJL/boxa/main/install.sh -o install.sh
     less install.sh
     bash install.sh

  2. Or pass --yes to accept all prompts:
     curl ... | bash -s -- --yes

EOF
    exit 1
fi

# --- OS / package manager detection ------------------------------------------

detect_os() {
    info "Detecting operating system..."

    case "$(uname -s)" in
        Darwin)
            OS="macos"
            PM="brew"
            if ! has brew; then
                error "Homebrew is required on macOS. Install from https://brew.sh"
            fi
            msg "macOS detected (Homebrew)"
            return
            ;;
        Linux) ;;
        *) error "Unsupported OS: $(uname -s)" ;;
    esac

    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case "${ID:-}" in
            ubuntu|debian|pop|mint|raspbian|linuxmint) PM="apt-get" ;;
            fedora|rhel|centos|rocky|almalinux)        PM="dnf" ;;
            arch|manjaro|endeavouros)                   PM="pacman" ;;
            opensuse*|sles)                             PM="zypper" ;;
            alpine)                                     PM="apk" ;;
        esac
    fi

    # Fallback: detect by available command
    if [ -z "$PM" ]; then
        for pm in apt-get dnf pacman zypper apk; do
            if has "$pm"; then PM="$pm"; break; fi
        done
    fi

    [ -n "$PM" ] || error "Could not detect package manager. Install git, Docker, and keychain manually."
    OS="linux"
    msg "Linux detected (${PM})"
}

# --- Package installation helpers --------------------------------------------

pkg_install() {
    local pkg="$1"
    case "$PM" in
        brew)    brew install "$pkg" ;;
        apt-get) sudo apt-get install -y "$pkg" ;;
        dnf)     sudo dnf install -y "$pkg" ;;
        pacman)  sudo pacman -S --noconfirm "$pkg" ;;
        zypper)  sudo zypper install -y "$pkg" ;;
        apk)     sudo apk add "$pkg" ;;
    esac
}

pkg_update() {
    case "$PM" in
        apt-get) sudo apt-get update ;;
        dnf)     ;; # dnf auto-refreshes
        pacman)  ;; # pacman -Sy without -u is unsafe; pacman -S handles it
        zypper)  sudo zypper refresh ;;
        apk)     sudo apk update ;;
        brew)    brew update ;;
    esac
}

# --- Install prerequisites ---------------------------------------------------

install_git() {
    info "Checking git..."
    if has git; then
        SKIPPED+=("git ($(git --version))")
        return
    fi
    msg "Installing git..."
    pkg_install git
    INSTALLED+=("git")
}

install_docker_ce() {
    # Linux: install Docker CE from official repo
    msg "Installing Docker CE from official repository..."

    # shellcheck disable=SC1091
    local docker_id=""
    if [ "$PM" = "apt-get" ]; then
        # shellcheck disable=SC1091  # /etc/os-release is a system file, not available to shellcheck
        docker_id=$(. /etc/os-release && echo "$ID")
        [[ "$docker_id" =~ ^[a-z]+$ ]] || error "Invalid OS ID for Docker repo: $docker_id"
    fi

    case "$PM" in
        apt-get)
            sudo apt-get install -y ca-certificates curl gnupg
            sudo install -m 0755 -d /etc/apt/keyrings
            if [ ! -f /etc/apt/keyrings/docker.asc ]; then
                curl -fsSL "https://download.docker.com/linux/${docker_id}/gpg" | sudo tee /etc/apt/keyrings/docker.asc > /dev/null
                sudo chmod a+r /etc/apt/keyrings/docker.asc
                # Verify Docker GPG key fingerprint
                if has gpg; then
                    local fingerprint
                    fingerprint=$(gpg --dry-run --quiet --import --import-options import-show /etc/apt/keyrings/docker.asc 2>/dev/null | grep -oE '[0-9A-F]{40}' | head -1)
                    if [ "$fingerprint" != "9DC858229FC7DD38854AE2D88D81803C0EBFCD88" ]; then
                        sudo rm -f /etc/apt/keyrings/docker.asc
                        error "Docker GPG key fingerprint mismatch! Expected 9DC8...CD88, got ${fingerprint:-none}"
                    fi
                    msg "Docker GPG key fingerprint verified."
                else
                    warn "gpg not available, skipping Docker GPG key fingerprint verification."
                fi
            fi
            # shellcheck disable=SC1091
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${docker_id} $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
                sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
            sudo apt-get update
            sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
        dnf)
            sudo dnf install -y dnf-plugins-core
            sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo 2>/dev/null || \
                sudo dnf config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo
            sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
        pacman)
            sudo pacman -S --noconfirm docker docker-buildx docker-compose
            ;;
        zypper)
            sudo zypper install -y docker docker-buildx docker-compose
            ;;
        apk)
            sudo apk add docker docker-cli-buildx docker-cli-compose
            ;;
    esac

    # Enable and start Docker
    if has systemctl; then
        sudo systemctl enable docker 2>/dev/null || true
        sudo systemctl start docker 2>/dev/null || true
    fi

    INSTALLED+=("Docker CE")
    DOCKER_STATE="running"
}

check_docker() {
    info "Checking Docker..."

    # 1. Docker binary exists and daemon responds
    if has docker && docker info &>/dev/null 2>&1; then
        DOCKER_STATE="running"
        SKIPPED+=("Docker ($(docker --version 2>/dev/null | head -c 60))")
        return
    fi

    # 2. Docker binary exists but daemon not responding
    if has docker; then
        DOCKER_STATE="installed"
        warn "Docker is installed but not running."
        if is_wsl2; then
            msg "Start Docker Desktop on Windows, or start the Docker daemon."
        else
            msg "Start the Docker daemon (e.g. sudo systemctl start docker)."
        fi
        SKIPPED+=("Docker (installed but not running)")
        return
    fi

    # 3. Docker Desktop detected but binary not available
    if is_wsl2 && [ -d "/mnt/c/Program Files/Docker" ]; then
        DOCKER_STATE="desktop"
        warn "Docker Desktop is installed on Windows but not available in WSL2."
        msg "Start Docker Desktop and enable WSL2 integration in Settings."
        SKIPPED+=("Docker (Desktop installed, not available in WSL2)")
        return
    fi

    if [ "$OS" = "macos" ] && [ -d "/Applications/Docker.app" ]; then
        DOCKER_STATE="desktop"
        warn "Docker Desktop is installed but not running."
        msg "Start Docker Desktop from Applications."
        SKIPPED+=("Docker (Desktop installed, not running)")
        return
    fi

    # 4. Docker not found at all
    DOCKER_STATE="missing"

    if [ "$OS" = "macos" ]; then
        warn "Docker is not installed."
        msg "Install Docker via one of:"
        msg "  - Docker Desktop: https://www.docker.com/products/docker-desktop/"
        msg "  - OrbStack:       https://orbstack.dev"
        msg "  - Colima:         brew install colima docker docker-compose"
        SKIPPED+=("Docker (not installed)")
        return
    fi

    if is_wsl2; then
        warn "Docker is not installed."
        msg "Recommended: Install Docker Desktop for Windows with WSL2 integration."
        msg "  https://www.docker.com/products/docker-desktop/"
        msg ""
        if confirm "Install Docker CE inside WSL2 instead?"; then
            install_docker_ce
        else
            SKIPPED+=("Docker (not installed)")
        fi
        return
    fi

    # Native Linux
    if $AUTO_YES; then
        install_docker_ce
    elif confirm "Install Docker CE?"; then
        install_docker_ce
    else
        SKIPPED+=("Docker (not installed)")
    fi
}

add_docker_group() {
    if [ "$OS" != "linux" ]; then return; fi
    if ! has docker; then return; fi
    if id -nG "$USER" 2>/dev/null | grep -qw docker; then
        SKIPPED+=("docker group (already member)")
        return
    fi
    if ! getent group docker &>/dev/null; then
        sudo groupadd docker 2>/dev/null || true
    fi
    info "Adding $USER to docker group..."
    sudo usermod -aG docker "$USER"
    CONFIGURED+=("docker group membership")
    NEED_RELOGIN=true
}

install_keychain() {
    info "Checking keychain..."
    if has keychain; then
        SKIPPED+=("keychain (already installed)")
        return
    fi
    msg "Installing keychain..."
    pkg_install keychain
    INSTALLED+=("keychain")
}

# --- Agent-browser xhost dependency (ADR 0010, issue 13) ---------------------
# Provisions the `xhost` tool that the broker uses to grant the boxa-agent
# OS user access to the developer's X display before launching Host agent
# Chrome (issue 12's `_grant_agent_x_display_access`). Without xhost the grant
# fails and Chrome dies with an X-authorization error.
#
# Gating mirrors the broker's grant path exactly (agent-browser-broker.sh
# `_grant_agent_x_display_access`): native Linux ONLY. macOS uses Quartz (no
# xhost); WSL2 uses WSLg, whose Wayland/Xwayland sockets are world-readable so
# boxa-agent connects without an xhost grant — installing it there would be
# noise. The broker skips xhost on those platforms, so install.sh does too.
#
# Idempotent: a no-op when `xhost` is already present. Package names match the
# broker's missing-xhost hint so the two never contradict each other.

install_xhost() {
    info "Checking xhost (agent-browser X display grant)..."

    # Native Linux only — skip macOS (Quartz) and WSL2 (WSLg world-readable
    # sockets). Matches the broker's grant-path gating.
    if [ "$OS" != "linux" ]; then
        SKIPPED+=("xhost (not needed on $OS)")
        return
    fi
    if is_wsl2; then
        SKIPPED+=("xhost (not needed on WSL2/WSLg)")
        return
    fi

    if has xhost; then
        SKIPPED+=("xhost (already installed)")
        return
    fi

    # Package name per distro family. Mirrors the broker's missing-xhost
    # hint (agent-browser-broker.sh `_grant_agent_x_display_access`).
    local pkg=""
    case "$PM" in
        apt-get)        pkg="x11-xserver-utils" ;;
        dnf)            pkg="xorg-x11-server-utils" ;;
        pacman)         pkg="xorg-xhost" ;;
        zypper)         pkg="xhost" ;;
        apk)            pkg="xhost" ;;
        *)
            warn "Don't know the xhost package name for package manager '$PM'."
            msg "Install the X11 client tools providing 'xhost' manually for agent-browser."
            SKIPPED+=("xhost (unknown package for $PM)")
            return
            ;;
    esac

    msg "Installing xhost ($pkg)..."
    pkg_install "$pkg"
    INSTALLED+=("xhost ($pkg)")
}

# --- mkcert ------------------------------------------------------------------
# mkcert backs the HTTPS-by-default rollout (ADR 0008). The actual fetch +
# SHA-256 verify + binary placement lives in scripts/install-mkcert.sh so the
# HTTPS upgrade orchestration (`_dns::install_ca` and `_boxa::run_https_upgrade`)
# can call the same provisioner without dragging in install.sh's repo-clone
# and symlink-replace side effects — see install-mkcert.sh's header for why
# that split exists. install.sh keeps `install_mkcert` as a thin wrapper so
# the summary still tracks INSTALLED/SKIPPED for the user.

install_mkcert() {
    info "Checking mkcert..."

    # Delegate to scripts/ensure-mkcert.sh — the same registry step
    # `boxa doctor` / the `boxa update` self-heal drive, so install-time
    # and registry paths run identical logic (ADR 0017). The ensure script
    # itself wraps scripts/install-mkcert.sh (which owns the version pin,
    # SHA-256 table, and download); no logic is duplicated here.
    local provisioner="$BOXA_DIR/scripts/ensure-mkcert.sh"
    if [ ! -x "$provisioner" ]; then
        warn "scripts/ensure-mkcert.sh missing or non-executable; skipping mkcert."
        SKIPPED+=("mkcert (provisioner script missing)")
        return
    fi

    # `--with-nss` lets the provisioner install libnss3-tools (or equivalent)
    # on Linux when certutil is absent — without it `mkcert -install` warns
    # and silently skips Firefox/Chrome trust. macOS uses the Keychain so
    # the flag is a no-op there; the provisioner short-circuits before any
    # sudo prompt.
    local extra_args=()
    [ "$OS" = "linux" ] && extra_args+=("--with-nss")

    # Capture the resolved binary path so the summary line is precise. On a
    # fresh install the ensure script prints the binary path on stdout when
    # it installs; on an already-present host it prints a "no changes" note.
    # Either way rc=0 means a usable mkcert exists; diagnostics land on
    # stderr and pass straight through so the user sees download progress.
    local resolved=""
    if resolved="$("$provisioner" "${extra_args[@]}")"; then
        INSTALLED+=("mkcert (${resolved:-already present})")
    else
        SKIPPED+=("mkcert (install failed; see warnings above)")
    fi
}

# --- Host DNS resolver + mkcert CA (ADR 0007 / 0008) -------------------------
# Wire up the per-OS `.test` host resolver (and the mkcert root CA) during the
# initial install, fulfilling ADR 0007's promise that this is "Auto-triggered
# by install.sh (first-time install)". install.sh is the right home: it is the
# one interactive moment where a sudo / Touch ID prompt is expected, and
# dns-install shares that single auth session for both the resolver write and
# the CA install — so the user can't approve one and silently miss the other
# (the split that used to strand `.test` on the sslip.io fallback).
#
# Needs neither Docker nor the boxa image: the boxa_dns container starts later
# via bootstrap_dns, and dns-install defers resolver verification until it is
# up. Safe to run before `boxa build`.
#
# Non-fatal. dns-install returns non-zero only for a FIXABLE resolver failure
# (declined prompt / write error) — `.test` is then missing but recoverable, so
# we surface it in the ACTION REQUIRED block. A durable external fallback
# (port 53 busy, unsupported platform) returns 0 and is reported as a normal
# install outcome.
setup_dns() {
    info "Setting up host DNS resolver for .test..."

    local script="$BOXA_DIR/scripts/dns-install.sh"
    if [ ! -x "$script" ]; then
        warn "scripts/dns-install.sh missing or non-executable; skipping .test resolver setup."
        SKIPPED+=(".test DNS resolver (script missing) — run 'boxa dns-install' later")
        return
    fi

    # Honour an existing explicit external-mode choice. install.sh is re-runnable
    # on an existing checkout (setup_boxa_repo just pulls), so a plain `install`
    # here would re-attempt local and rewrite a user's deliberate
    # `boxa dns-install --external` back to local. Re-affirm external instead —
    # still idempotent and still installs the CA. A fresh install (no dns.conf)
    # or a local/degraded one falls through to auto, which re-heals local.
    local dns_conf="${BOXA_DNS_CONF:-$HOME/.config/boxa/dns.conf}"
    local ok=false
    if [ -f "$dns_conf" ] \
        && grep -qE '^[[:space:]]*preferred[[:space:]]*=[[:space:]]*external[[:space:]]*$' "$dns_conf"; then
        info "Existing dns.conf prefers external mode — keeping it (sslip.io URLs)."
        "$script" install --external && ok=true
    else
        "$script" install && ok=true
    fi

    if $ok; then
        INSTALLED+=(".test host DNS resolver + mkcert CA")
    else
        # dns-install already printed its own loud, actionable banner. Mirror
        # the one-line recovery into ACTION REQUIRED so it survives the scroll
        # to the end of a long install.
        ACTION_REQUIRED+=(".test host resolver was not set up — re-run 'boxa dns-install --local' to retry.
Boxa URLs use the sslip.io fallback meanwhile and still work.")
    fi
}

# --- Allow-for host state (ADR 0009) -----------------------------------------
# Provisions /var/log/boxa/allow-for/ (root-owned, mounted into containers)
# and, on WSL2, the toast notification AppId. install.sh is the canonical
# creation path; `boxa update` runs the same provisioner as a self-heal
# for existing installs that predate ADR 0009. The script is idempotent and
# only fires sudo when the dir is missing or has wrong perms.

setup_allow_for_state() {
    info "Configuring allow-for host state..."

    local provisioner="$BOXA_DIR/scripts/ensure-allow-for-host-state.sh"
    if [ ! -x "$provisioner" ]; then
        warn "scripts/ensure-allow-for-host-state.sh missing or non-executable; skipping."
        SKIPPED+=("allow-for host state (provisioner script missing)")
        return
    fi

    if "$provisioner"; then
        CONFIGURED+=("allow-for host state (/var/log/boxa/allow-for + WSL toast AppId)")
    else
        SKIPPED+=("allow-for host state (setup failed; see warnings above)")
    fi
}

# --- Agent-browser OS user (ADR 0010) ----------------------------------------
# Provisions the `boxa-agent` host OS user that Host agent Chrome runs
# under. The OS-identity separation is the primary defence the agent-browser
# feature buys (see ADR 0010 § Actor 1) — without it, Chrome with
# --user-data-dir alone could still file:// the developer's home or write
# autostart payloads as the real user. Idempotent: a second run is a no-op
# when the user already exists. Sudo prompts only on first install
# (Linux/WSL2: useradd; macOS: sysadminctl).

setup_agent_user() {
    info "Configuring boxa-agent OS user (agent-browser feature)..."

    local lib="$BOXA_DIR/lib/host-platform.sh"
    if [ ! -r "$lib" ]; then
        warn "lib/host-platform.sh missing; skipping boxa-agent user creation."
        SKIPPED+=("boxa-agent user (host-platform.sh missing)")
        return
    fi

    local user_created=false
    if id boxa-agent >/dev/null 2>&1; then
        SKIPPED+=("boxa-agent user (already exists)")
        user_created=true
    else
        # shellcheck source=lib/host-platform.sh disable=SC1091
        if ( . "$lib" && host_platform::ensure_agent_user ); then
            CONFIGURED+=("boxa-agent user (created)")
            user_created=true
        else
            warn "Failed to create boxa-agent user — boxa agent-browser commands will not work until this is fixed."
            SKIPPED+=("boxa-agent user (creation failed; see warnings above)")
        fi
    fi

    if [ "$user_created" != true ]; then
        return
    fi

    # Delegate group provisioning + invoker membership to the dedicated
    # host-state script — the same one `boxa update` self-heals
    # through, so install-time and upgrade-time paths stay in lockstep.
    # ADR 0010 documents the group-read path for the developer; without
    # it the forensic output (netlog, proxy log, summary) the CLI
    # advertises is locked behind sudo.
    local host_state_script="$BOXA_DIR/scripts/ensure-agent-browser-host-state.sh"
    if [ ! -x "$host_state_script" ]; then
        warn "scripts/ensure-agent-browser-host-state.sh missing or non-executable; group provisioning skipped."
        SKIPPED+=("boxa-agent group provisioning (script missing)")
        return
    fi

    if "$host_state_script"; then
        CONFIGURED+=("boxa-agent group provisioned ($USER membership configured)")
        if ! id -nG "$USER" 2>/dev/null | tr ' ' '\n' | grep -qx boxa-agent; then
            warn "Re-login (or run 'newgrp boxa-agent') so the new group membership takes effect in your current shell."
        fi
    else
        warn "Failed to provision boxa-agent group state — agent-browser artefacts will not be readable without sudo."
        SKIPPED+=("boxa-agent group provisioning (failed; see warnings above)")
    fi
}

# --- WSL2 drvfs mount guard (agent-browser isolation) ------------------------
# WSL2's default drvfs permissions make /mnt/c world-readable to every Linux
# OS user, including boxa-agent. Delegate the section-aware /etc/wsl.conf
# hardening to the category-A provisioner so install, update, and doctor share
# one implementation.

setup_wsl_mount_guard() {
    info "Configuring WSL /mnt umask guard..."

    local provisioner="$BOXA_DIR/scripts/ensure-wsl-mount-guard.sh"
    if [ ! -x "$provisioner" ]; then
        warn "scripts/ensure-wsl-mount-guard.sh missing or non-executable; skipping."
        SKIPPED+=("WSL /mnt umask guard (provisioner script missing)")
        return
    fi

    if "$provisioner"; then
        CONFIGURED+=("WSL /mnt umask guard")
    else
        warn "Failed to configure WSL /mnt umask guard — see warnings above."
        SKIPPED+=("WSL /mnt umask guard (setup failed; see warnings above)")
    fi
}

# --- Agent-browser Python helpers (ADR 0010) ---------------------------------
# Delegates to scripts/ensure-agent-browser-helpers.sh — the same script
# `boxa update` self-heals existing installs through, so install-time
# and upgrade-time paths stay in lockstep.

stage_agent_browser_helpers() {
    info "Staging agent-browser Python helpers..."

    local provisioner="$BOXA_DIR/scripts/ensure-agent-browser-helpers.sh"
    if [ ! -x "$provisioner" ]; then
        warn "scripts/ensure-agent-browser-helpers.sh missing or non-executable; skipping."
        SKIPPED+=("agent-browser helpers (provisioner missing)")
        return
    fi

    if "$provisioner"; then
        CONFIGURED+=("agent-browser helpers staged (/usr/local/lib/boxa/agent-browser)")
    else
        warn "Failed to stage agent-browser helpers — boxa agent-browser will not start."
        SKIPPED+=("agent-browser helpers (stage failed; see warnings above)")
    fi
}

# --- Upstream agent-browser skill (ADR 0011) ---------------------------------
# Delegates to scripts/ensure-upstream-agent-browser-skill.sh — the same
# script `boxa update` self-heals existing installs through, so install-time
# and upgrade-time paths stay in lockstep. The helper invokes
# `npx skills add vercel-labs/agent-browser …` headlessly. Soft failures
# (npx missing, network down) surface as install warnings instead of aborting
# the install.

setup_upstream_agent_browser_skill() {
    info "Installing upstream vercel-labs/agent-browser skill..."

    local provisioner="$BOXA_DIR/scripts/ensure-upstream-agent-browser-skill.sh"
    if [ ! -x "$provisioner" ]; then
        warn "scripts/ensure-upstream-agent-browser-skill.sh missing or non-executable; skipping."
        SKIPPED+=("upstream agent-browser skill (provisioner script missing)")
        return
    fi

    if "$provisioner"; then
        CONFIGURED+=("upstream agent-browser skill (~/.agents/skills/agent-browser)")
    else
        warn "Failed to install upstream agent-browser skill — see warnings above."
        SKIPPED+=("upstream agent-browser skill (install failed; see warnings above)")
    fi
}

# --- Agent-browser allowlist example file (ADR 0010) -------------------------
# Ships a documented `.example` copy of the agent-browser allowlist so the
# user has a template to copy when they decide to enable the feature. We
# never overwrite the real `agent-browser-allowed-domains.conf` even if
# present — the user's edits are sacred. Idempotent.

setup_agent_allowlist_example() {
    info "Installing agent-browser allowlist example..."

    # Delegate to scripts/ensure-agent-allowlist-example.sh — the same
    # registry step `boxa doctor` / the `boxa update` self-heal drive,
    # so install-time and registry paths write the byte-identical example
    # file (ADR 0017). No inline heredoc here anymore.
    local provisioner="$BOXA_DIR/scripts/ensure-agent-allowlist-example.sh"
    if [ ! -x "$provisioner" ]; then
        warn "scripts/ensure-agent-allowlist-example.sh missing or non-executable; skipping."
        SKIPPED+=("agent-browser allowlist example (provisioner script missing)")
        return
    fi

    local example="${XDG_CONFIG_HOME:-$HOME/.config}/boxa/agent-browser-allowed-domains.conf.example"
    if "$provisioner"; then
        CONFIGURED+=("agent-browser allowlist example ($example)")
    else
        SKIPPED+=("agent-browser allowlist example (setup failed; see warnings above)")
    fi
}

# --- Boxa agent skill (ADR 0011) -------------------------------------------
# Delegates to scripts/ensure-boxa-skill.sh — the same script
# `boxa update` self-heals existing installs through, so install-time
# and upgrade-time paths stay in lockstep. Seeds the host-shared
# 'boxa' skill at ~/.agents/skills/boxa/ + per-agent symlinks for
# Claude Code and Codex so every Container picks it up via the existing
# host bind mounts (ADR 0002).

setup_boxa_skill() {
    info "Installing boxa agent skill..."

    local provisioner="$BOXA_DIR/scripts/ensure-boxa-skill.sh"
    if [ ! -x "$provisioner" ]; then
        warn "scripts/ensure-boxa-skill.sh missing or non-executable; skipping."
        SKIPPED+=("boxa agent skill (provisioner missing)")
        return
    fi

    if "$provisioner"; then
        CONFIGURED+=("boxa agent skill (~/.agents/skills/boxa + Claude/Codex symlinks)")
    else
        warn "Failed to seed boxa agent skill — agents will lack boxa-aware context."
        SKIPPED+=("boxa agent skill (setup failed; see warnings above)")
    fi
}

# --- MCP onboarding (ADR 0013) -----------------------------------------------
# Delegates to scripts/ensure-mcp-onboarding.sh — the same hook the
# `boxa update` self-heal chain calls, so install-time and upgrade-time
# paths stay in lockstep. On a fresh interactive install it offers to scan
# existing Claude Code / Codex MCP servers for boxa import; non-interactive
# installs print a follow-up command instead (never a prompt or picker).

setup_mcp_onboarding() {
    info "Checking MCP onboarding..."

    local hook="$BOXA_DIR/scripts/ensure-mcp-onboarding.sh"
    if [ ! -x "$hook" ]; then
        warn "scripts/ensure-mcp-onboarding.sh missing or non-executable; skipping."
        SKIPPED+=("MCP onboarding (hook missing)")
        return
    fi

    # A piped/`--yes` install has no usable TTY for the wizard; force the
    # non-interactive branch so it prints the follow-up command instead of
    # blocking on a prompt. An interactive install runs the offer directly.
    local hook_args=()
    if $AUTO_YES || [ ! -t 0 ]; then
        hook_args+=("--non-interactive")
    fi

    if "$hook" "${hook_args[@]}"; then
        CONFIGURED+=("MCP onboarding (run 'boxa mcp import' to discover servers)")
    else
        warn "MCP onboarding check failed — run 'boxa mcp import' manually later."
        SKIPPED+=("MCP onboarding (check failed; see warnings above)")
    fi
}

# --- SSH agent configuration -------------------------------------------------

configure_ssh_agent() {
    info "Configuring SSH agent..."

    # Determine login shell profile (runs once per session, not managed by dotfiles)
    # IMPORTANT: For bash, prefer existing ~/.profile over creating ~/.bash_profile.
    # Bash reads ~/.bash_profile first and STOPS — creating it shadows ~/.profile,
    # breaking any existing user/system configuration there.
    local rc_file
    case "$(basename "${SHELL:-/bin/bash}")" in
        zsh)  rc_file="$HOME/.zprofile" ;;
        bash)
            if [ -f "$HOME/.bash_profile" ]; then
                rc_file="$HOME/.bash_profile"
            else
                rc_file="$HOME/.profile"
            fi
            ;;
        *)    rc_file="$HOME/.profile" ;;
    esac

    local marker="# Boxa: persistent SSH agent via keychain"

    if has keychain; then
        if grep -qF -- "$marker" "$rc_file" 2>/dev/null; then
            SKIPPED+=("keychain in $rc_file (already configured)")
        else
            msg "Adding keychain eval to $rc_file..."
            local keychain_cmd
            if [ "$OS" = "macos" ]; then
                # shellcheck disable=SC2016  # intentionally writing literal $() into shell rc file
                keychain_cmd='eval $(keychain --eval --quiet --agents ssh --inherit any)'
            else
                # shellcheck disable=SC2016
                keychain_cmd='eval $(keychain --eval --quiet --agents ssh)'
            fi
            printf '\n%s\n%s\n' "$marker" "$keychain_cmd" >> "$rc_file"
            CONFIGURED+=("keychain in $rc_file")
        fi
    else
        warn "keychain not found, skipping shell RC configuration"
    fi

    # SSH config: AddKeysToAgent
    local ssh_dir="$HOME/.ssh"
    local ssh_config="$ssh_dir/config"
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"

    if grep -qF "AddKeysToAgent" "$ssh_config" 2>/dev/null; then
        SKIPPED+=("AddKeysToAgent in ssh config (already set)")
    else
        msg "Adding AddKeysToAgent to $ssh_config..."
        local ssh_block
        ssh_block="$(cat <<'SSH_EOF'
# Boxa: auto-add keys to agent on first SSH use
Host *
    AddKeysToAgent yes
    IgnoreUnknown UseKeychain
    UseKeychain yes

SSH_EOF
)"
        if [ -f "$ssh_config" ]; then
            # Prepend to existing config
            local tmp
            tmp=$(mktemp "$ssh_dir/config.XXXXXX")
            printf '%s\n' "$ssh_block" | cat - "$ssh_config" > "$tmp"
            mv "$tmp" "$ssh_config"
        else
            printf '%s\n' "$ssh_block" > "$ssh_config"
        fi
        chmod 600 "$ssh_config"
        CONFIGURED+=("AddKeysToAgent in $ssh_config")
    fi
}

# --- Claude Code setup-token ------------------------------------------------

setup_claude_token() {
    info "Checking Claude Code token..."

    local token_file="$HOME/.config/boxa/claude-token"

    if [ -f "$token_file" ]; then
        CLAUDE_AUTH="have-token"
        SKIPPED+=("Claude token (already configured)")
        return
    fi

    # macOS: host login is NEVER shared into containers. The macOS Claude app
    # keeps credentials in the Keychain and deletes ~/.claude/.credentials.json
    # on /login (anthropics/claude-code#10039), so a token is the only way to
    # authenticate the container fleet — required regardless of any host file.
    if [ "$OS" = "macos" ]; then
        CLAUDE_AUTH="macos-token"
        warn "macOS: host Claude login is NOT shared into containers."
        msg "Run 'boxa claude-token' once to authenticate the container fleet."
        SKIPPED+=("Claude token (macOS: run 'boxa claude-token' to authenticate containers)")
        return
    fi

    if [ -f "$HOME/.claude/.credentials.json" ]; then
        CLAUDE_AUTH="auto"
        SKIPPED+=("Claude token (host OAuth credentials present, shared via bind mount)")
        return
    fi

    if ! has claude; then
        CLAUDE_AUTH="export"
        SKIPPED+=("Claude token (claude not installed on host)")
        return
    fi

    # claude is installed on host but there are no credentials yet (no token,
    # no .credentials.json) — nothing for the container to inherit, so the user
    # still has to authenticate. Surface the API-key step rather than claiming
    # it's automatic.
    CLAUDE_AUTH="export"
    msg "Run 'boxa claude-token' after install to set up a long-lived token."
    msg "This avoids daily re-login when using Claude Code in containers."
    SKIPPED+=("Claude token (run 'boxa claude-token' to set up)")
}

# --- Shell completion --------------------------------------------------------
#
# Two parallel completion files live in completions/:
#   _boxa       — zsh (`#compdef boxa`, native fpath-installed)
#   boxa.bash   — bash (`complete -F _boxa boxa`, sourced from .bashrc)
#
# Delegates to scripts/ensure-completions.sh — the same registry step
# `boxa doctor` / the `boxa update` self-heal drive, so install-time and
# registry paths install completions through one implementation (ADR 0017).
# The script routes by $SHELL (zsh: writable fpath → `sudo -n` → note;
# bash: marker-gated .bashrc source) and is idempotent.

setup_completions() {
    local provisioner="$BOXA_DIR/scripts/ensure-completions.sh"
    if [ ! -x "$provisioner" ]; then
        warn "scripts/ensure-completions.sh missing or non-executable; skipping."
        SKIPPED+=("shell completion (provisioner script missing)")
        return
    fi

    local shell_name
    shell_name="$(basename "${SHELL:-/bin/bash}")"
    case "$shell_name" in
        zsh|bash) ;;
        *)
            SKIPPED+=("shell completion (shell is $shell_name, not zsh or bash)")
            return
            ;;
    esac

    if "$provisioner"; then
        CONFIGURED+=("shell completion ($shell_name)")
    else
        SKIPPED+=("shell completion (setup failed; see warnings above)")
    fi
}

# --- Clipboard image keybinding ---------------------------------------------
# `boxa clip` (scripts/clip-image.sh) grabs a clipboard image and prints a path
# an agent can read. The key that triggers it lives in the user's terminal /
# compositor config, which install.sh does not own — so we detect what they run
# and print the exact snippet to paste (with the absolute inject-script path
# filled in). Full guide: docs/clipboard-images.md.

# macOS clipboard keybind automation. Split out of setup_clipboard_keybind
# because it does real work (brew installs, init.lua edit, permission
# prompts) rather than printing a snippet. Darwin-only — never reached on
# Linux/WSL2. Idempotent: re-running skips present brew packages and
# replaces (not duplicates) the managed Hammerspoon block.
setup_clipboard_keybind_macos() {
    # macOS forbids granting these programmatically — the user clicks once
    # in GUI. We trigger the prompts; the rest is automatic.
    if ! has brew; then
        msg "Homebrew not in PATH — install it (https://brew.sh), then re-run install.sh."
        msg "It will set up: hammerspoon (cask), terminal-notifier, pngpaste."
        SKIPPED+=("clipboard keybind (macOS — Homebrew missing)")
        return
    fi

    # (a) Install the tools idempotently. hammerspoon ships the global
    #     hotkey + keystroke injection; terminal-notifier gives clickable
    #     notifications; pngpaste lets clip-image.sh grab PNGs natively.
    if brew list --cask hammerspoon >/dev/null 2>&1; then
        SKIPPED+=("hammerspoon (already installed)")
    else
        msg "Installing hammerspoon (cask)..."
        # `if` (not `&&`) so a failed/cancelled cask install can't abort the
        # whole installer under `set -e` — we handle it via the check below.
        if brew install --cask hammerspoon; then INSTALLED+=("hammerspoon"); fi
    fi
    # Hammerspoon is the load-bearing dependency — the hotkey, injection and
    # config block are all pointless without it. If the cask install failed
    # or was cancelled, bail before writing config so we don't report the
    # keybind as configured when Ctrl+Shift+S can't possibly work.
    if ! brew list --cask hammerspoon >/dev/null 2>&1; then
        warn "Hammerspoon not installed — skipping clipboard keybind setup."
        warn "Re-run install.sh once 'brew install --cask hammerspoon' succeeds."
        SKIPPED+=("clipboard keybind (macOS — Hammerspoon install failed)")
        return
    fi
    local formula
    for formula in terminal-notifier pngpaste; do
        if brew list --formula "$formula" >/dev/null 2>&1; then
            SKIPPED+=("$formula (already installed)")
        else
            msg "Installing $formula..."
            if brew install "$formula"; then INSTALLED+=("$formula"); fi
        fi
    done

    # (b) Write the managed Hammerspoon block. We touch ONLY the text
    #     between the markers — anyone's existing init.lua survives intact.
    local init="$HOME/.hammerspoon/init.lua"
    local mark_begin="-- >>> boxa clipboard-image (managed) >>>"
    local mark_end="-- <<< boxa clipboard-image (managed) <<<"
    mkdir -p "$HOME/.hammerspoon"

    local block_file
    block_file=$(mktemp)
    cat > "$block_file" <<HS_BLOCK
$mark_begin
require("hs.ipc")
local CLIP_SCRIPT = os.getenv("HOME") .. "/.local/share/boxa/scripts/clip-image.sh"
hs.hotkey.bind({ "ctrl", "shift" }, "s", function()
  local out = hs.execute(CLIP_SCRIPT, true)
  out = (out or ""):gsub("%s+\$", "")
  if out ~= "" then
    hs.eventtap.keyStrokes(out)
  else
    hs.alert.show("boxa clip: žádný obrázek v clipboardu")
  end
end)
$mark_end
HS_BLOCK

    local has_begin=false has_end=false
    if [ -f "$init" ]; then
        # `--` so the markers (which start with `--`) aren't parsed as grep
        # options by BSD grep — without it the check always fails and the
        # managed block gets appended on every run.
        grep -qF -- "$mark_begin" "$init" && has_begin=true
        grep -qF -- "$mark_end" "$init" && has_end=true
    fi

    if $has_begin && $has_end; then
        # Replace in place: on the begin marker, emit the fresh block (which
        # carries its own markers) and skip the old body through end marker.
        awk -v b="$mark_begin" -v e="$mark_end" -v bf="$block_file" '
            $0 == b { skip=1; while ((getline line < bf) > 0) print line; close(bf); next }
            $0 == e { skip=0; next }
            !skip
        ' "$init" > "$init.boxa-tmp" || { rm -f "$init.boxa-tmp"; return; }
        # Write through the existing file (not `mv`) so a symlinked init.lua
        # — common with chezmoi/stow dotfiles — keeps its link and the
        # target's permissions instead of being replaced by a plain file.
        cat "$init.boxa-tmp" > "$init"
        rm -f "$init.boxa-tmp"
        msg "Updated managed Hammerspoon block in $init"
    elif $has_begin || $has_end; then
        # Exactly one marker — a half-written/hand-edited block. Appending
        # would nest blocks and the awk replace would truncate everything
        # after a lone begin marker, so refuse to touch the file and let the
        # user reconcile it. Non-destructive: init.lua is left exactly as-is.
        rm -f "$block_file"
        warn "Malformed boxa block in $init (only one marker present) — not touching it."
        warn "Remove the stray '-- >>> / <<< boxa clipboard-image' marker, then re-run install.sh."
        SKIPPED+=("clipboard keybind (macOS — malformed Hammerspoon block)")
        return
    else
        # Append, separated by a blank line if the file already has content.
        [ -s "$init" ] && printf '\n' >> "$init"
        cat "$block_file" >> "$init"
        msg "Added managed Hammerspoon block to $init"
    fi
    rm -f "$block_file"

    # (c) Start Hammerspoon and trigger ITS OWN Accessibility prompt, which
    #     deep-links straight to the Hammerspoon entry. We wait for the hs IPC
    #     to come up (it loads via require("hs.ipc") in the block above), then
    #     accessibilityState(true) raises Hammerspoon's "would like to control
    #     this computer" dialog with an "Open System Settings" button that
    #     lands directly on its row — far better than the generic Privacy pane.
    #     We restart Hammerspoon FIRST: `open -a` is a no-op when it's already
    #     running with a stale config, so the freshly-written block (hotkey +
    #     hs.ipc) wouldn't load and the hs CLI wait below would time out. The
    #     restart is BEFORE the prompt, so it doesn't kill the dialog that
    #     accessibilityState() raises afterwards. (The AXIsProcessTrusted()
    #     cache only affects what accessibilityState() *reports* — keyStrokes
    #     works the instant permission is granted — so no second restart.)
    killall Hammerspoon 2>/dev/null || true
    sleep 1
    open -a Hammerspoon 2>/dev/null || true
    local hs_ipc_ready=false
    if has hs; then
        for _ in $(seq 1 20); do
            hs -c "return 1" >/dev/null 2>&1 && { hs_ipc_ready=true; break; }
            sleep 0.5
        done
    fi

    # Drive the prompt and the ACTION REQUIRED note off the ACTUAL current
    # trust state. If Hammerspoon is already trusted, accessibilityState(true)
    # is a no-op and raises no dialog — telling the user to "enable
    # Hammerspoon" then would be misleading (nothing to do, nothing appeared).
    local already_trusted=false
    if $hs_ipc_ready && [ "$(hs -c "return hs.accessibilityState()" 2>/dev/null)" = "true" ]; then
        already_trusted=true
    fi

    if $already_trusted; then
        CONFIGURED+=("Hammerspoon accessibility (already granted)")
    else
        if $hs_ipc_ready; then
            # Raises Hammerspoon's own dialog, which deep-links to its entry.
            hs -c "hs.accessibilityState(true)" >/dev/null 2>&1 || true
        else
            # hs CLI absent or IPC never came up — open the generic pane so the
            # user still lands somewhere instead of at a dialog that never showed.
            open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true
        fi
        ACTION_REQUIRED+=("Enable Hammerspoon in System Settings → Privacy & Security → Accessibility.
   Hammerspoon's dialog has an \"Open System Settings\" button that takes you straight there.
   Without it, Ctrl+Shift+S fails silently — the PNG is saved but the path is never typed.
   If Hammerspoon is already ticked but doesn't work, toggle it off/on (or remove with − and re-add with +).")
    fi

    # (d) Notifications via terminal-notifier. Fire one test notification to
    #     trigger the macOS allow-notifications prompt (one grant covers all
    #     terminals), then open the panel and explain the Alerts switch —
    #     report persistence can't be set programmatically (ncprefs is
    #     protected and the flag encoding shifts between macOS releases).
    if has terminal-notifier; then
        terminal-notifier -title "boxa" -message "Notifikace nastaveny ✓" >/dev/null 2>&1 || true
        open "x-apple.systempreferences:com.apple.Notifications-Settings.extension" 2>/dev/null || true
        ACTION_REQUIRED+=("In System Settings → Notifications, find terminal-notifier and switch its style
   from Banners to Alerts, so harvest reports stay on screen until you acknowledge them.")
    fi

    CONFIGURED+=("clipboard keybind (macOS — Hammerspoon hotkey + terminal-notifier)")
}

setup_clipboard_keybind() {
    info "Clipboard image keybinding..."

    local inject="$BOXA_DIR/scripts/clip-image-inject.sh"

    # macOS: a global hotkey via Hammerspoon works in *every* terminal
    # (incl. Terminal.app, which can't run a command from a keybind). We
    # install the tools, drop a managed block into init.lua, and trigger
    # the two GUI permissions macOS won't grant programmatically.
    if [ "$OS" = "macos" ]; then
        setup_clipboard_keybind_macos
        return
    fi

    # WSL2: the keybind lives in WezTerm on the Windows side; clip-image.sh runs
    # in WSL via PowerShell and WezTerm captures+injects, so no inject tool needed.
    if is_wsl2; then
        msg "WSL2: add the WezTerm keybinding (Windows ~/.wezterm.lua) — see docs/clipboard-images.md."
        SKIPPED+=("clipboard keybind (WSL2 — WezTerm config is manual)")
        return
    fi

    # Native Linux: pick the inject backend for terminals that can't capture
    # output themselves (everything except WezTerm).
    local session inject_tool
    if [ -n "${WAYLAND_DISPLAY:-}" ] || [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
        session="Wayland"; inject_tool="wtype"
    else
        session="X11"; inject_tool="xdotool"
    fi

    # Detect terminal / compositor configs by presence.
    local wez_cfg=""
    if [ -f "$HOME/.wezterm.lua" ]; then
        wez_cfg="$HOME/.wezterm.lua"
    elif [ -f "$HOME/.config/wezterm/wezterm.lua" ]; then
        wez_cfg="$HOME/.config/wezterm/wezterm.lua"
    fi

    local -a found=()
    [ -n "$wez_cfg" ] && found+=("wezterm")
    [ -f "$HOME/.config/alacritty/alacritty.toml" ] && found+=("alacritty")
    [ -f "$HOME/.config/kitty/kitty.conf" ] && found+=("kitty")
    [ -f "$HOME/.config/ghostty/config" ] && found+=("ghostty")
    [ -f "$HOME/.config/hypr/hyprland.conf" ] && found+=("hyprland")
    [ -f "$HOME/.config/sway/config" ] && found+=("sway")

    if [ ${#found[@]} -eq 0 ]; then
        msg "No known terminal/compositor config detected."
        msg "See docs/clipboard-images.md to wire up a clip keybinding for yours."
        SKIPPED+=("clipboard keybind (no known terminal config found)")
        return
    fi

    msg "Detected: ${found[*]}"

    # Offer the inject tool if any detected target needs it (i.e. not pure WezTerm).
    local t needs_inject=false
    for t in "${found[@]}"; do
        [ "$t" != "wezterm" ] && needs_inject=true
    done
    if $needs_inject && ! has "$inject_tool"; then
        msg "$inject_tool not found (needed to type the path on $session)."
        if confirm "Install $inject_tool?"; then
            pkg_install "$inject_tool"
            INSTALLED+=("$inject_tool")
        else
            warn "Skipping $inject_tool; the inject keybind won't work until it's installed."
            SKIPPED+=("$inject_tool (clipboard inject tool)")
        fi
    fi

    # Print the matching snippet for each detected target (Ctrl+Shift+S).
    msg "Paste the matching keybinding (Ctrl+Shift+S); full guide: docs/clipboard-images.md"
    for t in "${found[@]}"; do
        echo ""
        case "$t" in
            wezterm)
                msg "wezterm → $wez_cfg: see docs/clipboard-images.md (Lua callback, goes inside your keys table)."
                ;;
            alacritty)
                msg "alacritty → ~/.config/alacritty/alacritty.toml:"
                printf '    [[keyboard.bindings]]\n    key = "S"\n    mods = "Control|Shift"\n    command = { program = "%s" }\n' "$inject"
                ;;
            kitty)
                msg "kitty → ~/.config/kitty/kitty.conf:"
                printf '    map ctrl+shift+s launch --type=background %s\n' "$inject"
                ;;
            hyprland)
                msg "hyprland → ~/.config/hypr/hyprland.conf:"
                printf '    bind = CTRL SHIFT, S, exec, %s\n' "$inject"
                ;;
            sway)
                msg "sway → ~/.config/sway/config:"
                printf '    bindsym Ctrl+Shift+s exec %s\n' "$inject"
                ;;
            ghostty)
                msg "ghostty can't spawn a command from a keybind — bind it in your compositor"
                msg "(Hyprland/Sway snippet above), pointing at:"
                printf '    %s\n' "$inject"
                ;;
        esac
    done

    CONFIGURED+=("clipboard keybind (printed snippet for: ${found[*]})")
}

# --- Clone / update boxa repo ---------------------------------------------

setup_boxa_repo() {
    info "Setting up boxa repository..."

    if [ -d "$BOXA_DIR" ]; then
        if [ -d "$BOXA_DIR/.git" ]; then
            local current_remote
            current_remote=$(git -C "$BOXA_DIR" remote get-url origin 2>/dev/null || echo "")
            if [ "$current_remote" = "$BOXA_REPO" ]; then
                msg "Updating existing boxa installation..."
                git -C "$BOXA_DIR" pull --ff-only
                SKIPPED+=("boxa repo (updated)")
                return
            else
                error "$BOXA_DIR exists but has different remote: $current_remote (expected $BOXA_REPO)"
            fi
        else
            error "$BOXA_DIR exists but is not a git repository"
        fi
    fi

    msg "Cloning boxa to $BOXA_DIR..."
    mkdir -p "$(dirname "$BOXA_DIR")"
    git clone "$BOXA_REPO" "$BOXA_DIR"
    INSTALLED+=("boxa repo")
}

# --- Dotfiles (chezmoi) choice ----------------------------------------------
# Lets the user pick their dotfiles strategy instead of inheriting the
# maintainer's personal repo (release issue #09). The decision is persisted to
# ~/.config/boxa/dotfiles.conf, which docker-run.sh sources to seed
# CHEZMOI_REPO on every container start:
#   1) boxa's bundled starter — BRAND_DOTFILES_REPO=bundled, applied locally
#      from the image by setup-chezmoi.sh (no network, no clone).
#   2) the user's own chezmoi repo URL
#   3) None — leaves CHEZMOI_REPO empty so setup-chezmoi.sh skips apply.
#
# The default value is read from the freshly-cloned lib/brand.sh (sourced here,
# now that the checkout exists) so install.sh never hardcodes it — brand.sh is
# the single source of truth (BRAND_DOTFILES_REPO). A non-interactive install
# (piped / --yes / no TTY) takes the bundled starter without prompting.

setup_dotfiles() {
    info "Configuring dotfiles (chezmoi)..."

    # The brand module is the single source of truth for the default starter
    # repo. It only exists after setup_boxa_repo cloned the checkout, so we
    # source it here rather than carrying a private copy of the value.
    local brand_lib="$BOXA_DIR/lib/brand.sh"
    local default_repo=""
    if [ -r "$brand_lib" ]; then
        # shellcheck source=lib/brand.sh disable=SC1091
        default_repo="$( . "$brand_lib" && printf '%s' "$BRAND_DOTFILES_REPO" )"
    fi
    if [ -z "$default_repo" ]; then
        warn "Could not read BRAND_DOTFILES_REPO from lib/brand.sh; skipping dotfiles setup."
        SKIPPED+=("dotfiles (brand default repo unavailable)")
        return
    fi

    local conf_dir="$HOME/.config/boxa"
    local conf_file="$conf_dir/dotfiles.conf"

    # Already chosen on a previous run — never clobber the user's decision.
    if [ -f "$conf_file" ]; then
        SKIPPED+=("dotfiles (already configured in $conf_file)")
        return
    fi

    local repo="$default_repo"

    # Non-interactive (piped / --yes / no TTY): take the default starter
    # silently, matching the old docker-run.sh default.
    if $AUTO_YES || [ ! -t 0 ]; then
        msg "Non-interactive install: using boxa's bundled dotfiles starter."
    else
        echo ""
        msg "Dotfiles setup:"
        msg "  1) Use boxa's bundled starter   (local, no network)   [default]"
        msg "  2) Use your own chezmoi repo    (enter URL)"
        msg "  3) None — pure bash"
        printf '\033[1;33m==> Choose [1/2/3] (default 1): \033[0m'
        read -r dotfiles_choice
        case "$dotfiles_choice" in
            ""|1)
                repo="$default_repo"
                ;;
            2)
                printf '\033[1;33m==> Enter chezmoi repo URL: \033[0m'
                read -r custom_repo
                if [ -z "$custom_repo" ]; then
                    warn "No URL entered; falling back to boxa's default dotfiles."
                    repo="$default_repo"
                else
                    repo="$custom_repo"
                fi
                ;;
            3)
                repo=""
                ;;
            *)
                warn "Unrecognized choice '$dotfiles_choice'; using boxa's default dotfiles."
                repo="$default_repo"
                ;;
        esac
    fi

    mkdir -p "$conf_dir"
    {
        printf '# boxa dotfiles choice — written by install.sh (release issue #09).\n'
        printf '# Sourced by docker-run.sh to seed CHEZMOI_REPO per container start.\n'
        printf '# Empty value = "None — pure bash" (chezmoi init/apply skipped).\n'
        printf 'CHEZMOI_REPO=%q\n' "$repo"
    } > "$conf_file"

    if [ "$repo" = "bundled" ]; then
        CONFIGURED+=("dotfiles (boxa bundled starter)")
    elif [ -n "$repo" ]; then
        CONFIGURED+=("dotfiles (chezmoi repo: $repo)")
    else
        CONFIGURED+=("dotfiles (none — pure bash)")
    fi
}

# --- Install boxa command --------------------------------------------------

install_command() {
    info "Installing boxa command..."

    local target="$BOXA_DIR/docker-run.sh"

    if [ ! -f "$target" ]; then
        warn "$target not found, skipping symlink."
        return
    fi

    chmod +x "$target"

    if [ -L "$SYMLINK_PATH" ]; then
        local current_target
        current_target=$(readlink "$SYMLINK_PATH")
        if [ "$current_target" = "$target" ]; then
            SKIPPED+=("boxa command (already linked)")
            return
        fi
        warn "$SYMLINK_PATH currently points to $current_target"
        if ! confirm "Replace symlink to point to $target?"; then
            SKIPPED+=("boxa command (kept existing)")
            return
        fi
    elif [ -e "$SYMLINK_PATH" ]; then
        warn "$SYMLINK_PATH exists and is not a symlink"
        if ! confirm "Replace $SYMLINK_PATH?"; then
            SKIPPED+=("boxa command (kept existing)")
            return
        fi
    fi

    # Try without sudo first, fall back to sudo
    if [ -w "$(dirname "$SYMLINK_PATH")" ]; then
        ln -sf "$target" "$SYMLINK_PATH"
    else
        sudo ln -sf "$target" "$SYMLINK_PATH"
    fi
    CONFIGURED+=("boxa command -> $target")
}

# --- Summary -----------------------------------------------------------------

print_summary() {
    echo ""
    success "Boxa installation complete!"
    echo ""

    if [ ${#INSTALLED[@]} -gt 0 ]; then
        msg "Installed:"
        for item in "${INSTALLED[@]}"; do msg "  + $item"; done
    fi

    if [ ${#CONFIGURED[@]} -gt 0 ]; then
        msg "Configured:"
        for item in "${CONFIGURED[@]}"; do msg "  ~ $item"; done
    fi

    if [ ${#SKIPPED[@]} -gt 0 ]; then
        msg "Skipped:"
        for item in "${SKIPPED[@]}"; do msg "  - $item"; done
    fi

    if $NEED_RELOGIN; then
        echo ""
        warn "You were added to the 'docker' group."
        msg "Log out and back in (or run: newgrp docker) for this to take effect."
    fi

    echo ""
    msg "SSH keys will be added to the agent automatically on first use"
    msg "(you'll be prompted for your passphrase once per session)."

    # --- Next steps ---
    echo ""
    info "Next steps:"

    local step=1

    case "$DOCKER_STATE" in
        running)
            ;;
        installed)
            msg "  ${step}. Start Docker daemon"
            if is_wsl2; then
                msg "     Start Docker Desktop on Windows, or: sudo systemctl start docker"
            elif [ "$OS" = "macos" ]; then
                msg "     Open Docker Desktop from Applications"
            else
                msg "     sudo systemctl start docker"
            fi
            step=$((step + 1))
            ;;
        desktop)
            msg "  ${step}. Start Docker Desktop"
            if is_wsl2; then
                msg "     Start Docker Desktop on Windows and enable WSL2 integration"
            else
                msg "     Open Docker Desktop from Applications"
            fi
            step=$((step + 1))
            ;;
        missing)
            msg "  ${step}. Install Docker"
            if [ "$OS" = "macos" ]; then
                msg "     Docker Desktop: https://www.docker.com/products/docker-desktop/"
                msg "     OrbStack:       https://orbstack.dev"
            elif is_wsl2; then
                msg "     Docker Desktop for Windows: https://www.docker.com/products/docker-desktop/"
                msg "     Or install Docker CE: see https://docs.docker.com/engine/install/"
            else
                msg "     See https://docs.docker.com/engine/install/"
            fi
            step=$((step + 1))
            ;;
    esac

    msg "  ${step}. Build the image:  boxa build"
    step=$((step + 1))

    # Auth step only when the user actually has to do something. have-token /
    # auto need nothing; macos-token needs `boxa claude-token` (not export);
    # only `export` (nothing to inherit) shows the API-key line.
    case "$CLAUDE_AUTH" in
        have-token|auto)
            ;;
        macos-token)
            msg "  ${step}. Authenticate the fleet: boxa claude-token"
            step=$((step + 1))
            ;;
        export|*)
            msg "  ${step}. Set your API key: export ANTHROPIC_API_KEY=sk-ant-..."
            step=$((step + 1))
            ;;
    esac

    msg "  ${step}. Run boxa:       boxa"

    # ACTION REQUIRED block — dead last and loudest, so the macOS GUI steps
    # are the final thing on screen (they're easy to miss mid-install).
    if [ ${#ACTION_REQUIRED[@]} -gt 0 ]; then
        local total=${#ACTION_REQUIRED[@]} idx=1 item
        for item in "${ACTION_REQUIRED[@]}"; do
            echo ""
            printf '\033[1;33m==> ACTION REQUIRED (%d/%d): %s\033[0m\n' "$idx" "$total" "$item"
            idx=$((idx + 1))
        done
        echo ""
    fi
}

# --- Main --------------------------------------------------------------------

main() {
    echo ""
    info "Boxa Installer"
    echo ""

    detect_os
    echo ""

    if ! $AUTO_YES; then
        msg "This script will:"
        msg "  1. Install git, keychain, and xhost (if missing; xhost = native Linux only)"
        msg "  2. Configure SSH agent via keychain"
        msg "  3. Clone boxa to $BOXA_DIR"
        msg "  4. Choose your dotfiles strategy (boxa bundled starter / your chezmoi repo / none)"
        msg "  5. Install mkcert v$MKCERT_VERSION + set up the .test host resolver & mkcert CA (sudo / Touch ID prompt)"
        msg "  6. Set up /var/log/boxa/allow-for (root-owned harvest log dir; sudo prompt)"
        msg "  7. Create boxa-agent OS user + add $USER to that group (agent-browser feature; sudo prompt)"
        msg "  8. Harden WSL2 drvfs automount permissions for agent-browser isolation"
        msg "  9. Stage agent-browser Python helpers to /usr/local/lib/boxa (sudo prompt)"
        msg " 10. Install upstream vercel-labs/agent-browser skill via 'npx skills add' (network)"
        msg " 11. Install agent-browser allowlist example to \$HOME/.config/boxa"
        msg " 12. Install 'boxa' agent skill to \$HOME/.agents/skills/boxa (+ Claude/Codex symlinks)"
        msg " 13. Offer MCP onboarding (scan existing Claude Code / Codex MCP servers for boxa import)"
        msg " 14. Install 'boxa' command to $SYMLINK_PATH"
        msg " 15. Detect your terminal and print the clipboard-image keybinding snippet"
        msg " 16. Optionally generate Claude Code token for containers"
        msg " 17. Check Docker availability"
        echo ""
        if ! confirm "Continue?"; then
            msg "Aborted."
            exit 0
        fi
        echo ""
    fi

    pkg_update

    install_git
    install_keychain
    install_xhost

    echo ""
    configure_ssh_agent

    echo ""
    setup_boxa_repo

    echo ""
    setup_dotfiles

    echo ""
    install_mkcert

    echo ""
    setup_dns

    echo ""
    setup_allow_for_state

    echo ""
    setup_agent_user

    echo ""
    setup_wsl_mount_guard

    echo ""
    stage_agent_browser_helpers

    echo ""
    setup_upstream_agent_browser_skill

    echo ""
    setup_agent_allowlist_example

    echo ""
    setup_boxa_skill

    echo ""
    setup_mcp_onboarding

    echo ""
    install_command

    echo ""
    setup_completions

    echo ""
    setup_clipboard_keybind

    echo ""
    setup_claude_token

    echo ""
    check_docker
    add_docker_group

    print_summary
}

main
