#!/usr/bin/env bash
set -euo pipefail

# Canonical lifecycle for the optional keep-awake host daemon. The CLI,
# provisioning registry, installer, and uninstaller all delegate here so the
# binary, platform autostart, and global Host connection converge together.

BOXA_DIR="${BOXA_DIR:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
# shellcheck source=../lib/keep-awake-probe.sh disable=SC1091
source "$BOXA_DIR/lib/keep-awake-probe.sh"
KEEP_AWAKE_PORT="${BOXA_KEEP_AWAKE_PORT:-17777}"
KEEP_AWAKE_TASK_NAME="BoxaKeepAwake"
KEEP_AWAKE_FIREWALL_RULE_NAME="BoxaKeepAwakeWSL"
KEEP_AWAKE_FIREWALL_RULE_DISPLAY_NAME="Boxa Keep-Awake (WSL)"
KEEP_AWAKE_LAUNCH_LABEL="dev.boxa.keep-awake"
KEEP_AWAKE_TRAY_TASK_NAME="BoxaKeepAwakeTray"
KEEP_AWAKE_TRAY_LAUNCH_LABEL="dev.boxa.keep-awake-tray"
KEEP_AWAKE_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/boxa"
KEEP_AWAKE_STATE_FILE="$KEEP_AWAKE_CONFIG_DIR/keep-awake.conf"
KEEP_AWAKE_CONNECT_FILE="$KEEP_AWAKE_CONFIG_DIR/connect/_all.tsv"
KEEP_AWAKE_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/boxa/keep-awake"
KEEP_AWAKE_RELAY_STATE_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/boxa/host-connections/${KEEP_AWAKE_PORT}.state"
KEEP_AWAKE_LOG_FILE="$KEEP_AWAKE_STATE_DIR/keep-awake.log"
KEEP_AWAKE_PLATFORM=""
KEEP_AWAKE_INSTALL_DIR=""
KEEP_AWAKE_BINARY=""
KEEP_AWAKE_WINDOWS_BINARY=""
KEEP_AWAKE_WINDOWS_LOG=""
KEEP_AWAKE_WRAPPER=""
KEEP_AWAKE_WINDOWS_WRAPPER=""
KEEP_AWAKE_AUTOSTART_FILE=""
KEEP_AWAKE_TRAY_FILE=""
KEEP_AWAKE_TRAY_BINARY=""
KEEP_AWAKE_TRAY_AUTOSTART_FILE=""
KEEP_AWAKE_TRAY_BUSY_ICON=""
KEEP_AWAKE_TRAY_IDLE_ICON=""
KEEP_AWAKE_WINDOWS_TRAY_FILE=""
KEEP_AWAKE_BOXA="${BOXA_KEEP_AWAKE_BOXA_COMMAND:-$BOXA_DIR/docker-run.sh}"
KEEP_AWAKE_GO_IMAGE="golang:1.22"
KEEP_AWAKE_CLAUDE_DEFAULTS="${BOXA_KEEP_AWAKE_CLAUDE_DEFAULTS:-$BOXA_DIR/config/claude}"

usage() {
    cat <<'EOF'
Usage: ensure-keep-awake.sh <offer|probe|enable|refresh|disable|status|teardown|go-prereq|go-remedy> [options]

Canonical lifecycle helper for boxa's elective keep-awake daemon.

Options for offer:
  --yes              Enable without prompting.
  --non-interactive  Print the later-enable command without recording a choice.
  --interactive      Force the prompt (test seam).

Options for enable:
  --autostart MODE   Start mode: system (default), terminal, or none.

Options for teardown:
  --keep-connection  Leave Host connection removal to the caller's sweep.
  --remove-state     Remove the elective marker (uninstall).
EOF
}

keep_awake::platform() {
    if [ -n "${BOXA_KEEP_AWAKE_PLATFORM:-}" ]; then
        printf '%s\n' "$BOXA_KEEP_AWAKE_PLATFORM"
        return 0
    fi
    # Runtime BOXA_DIR may point at an installed checkout or a test fixture.
    # shellcheck source=../lib/host-platform.sh disable=SC1091
    source "$BOXA_DIR/lib/host-platform.sh"
    host_platform::detect
}

keep_awake::init_paths() {
    KEEP_AWAKE_PLATFORM="$(keep_awake::platform)" || {
        printf 'keep-awake: unsupported host platform.\n' >&2
        return 1
    }
    case "$KEEP_AWAKE_PLATFORM" in
        linux)
            KEEP_AWAKE_INSTALL_DIR="${BOXA_KEEP_AWAKE_INSTALL_DIR:-$HOME/.local/lib/boxa/keep-awake}"
            KEEP_AWAKE_BINARY="$KEEP_AWAKE_INSTALL_DIR/keep-awake"
            KEEP_AWAKE_AUTOSTART_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/boxa-keep-awake.service"
            KEEP_AWAKE_TRAY_FILE="$KEEP_AWAKE_INSTALL_DIR/keep-awake-tray.sh"
            KEEP_AWAKE_TRAY_AUTOSTART_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/boxa-keep-awake-tray.service"
            KEEP_AWAKE_TRAY_BUSY_ICON="$KEEP_AWAKE_INSTALL_DIR/busy.svg"
            KEEP_AWAKE_TRAY_IDLE_ICON="$KEEP_AWAKE_INSTALL_DIR/idle.svg"
            ;;
        macos)
            KEEP_AWAKE_INSTALL_DIR="${BOXA_KEEP_AWAKE_INSTALL_DIR:-$HOME/Library/Application Support/Boxa}"
            KEEP_AWAKE_BINARY="$KEEP_AWAKE_INSTALL_DIR/keep-awake"
            KEEP_AWAKE_AUTOSTART_FILE="$HOME/Library/LaunchAgents/${KEEP_AWAKE_LAUNCH_LABEL}.plist"
            KEEP_AWAKE_TRAY_FILE="$KEEP_AWAKE_INSTALL_DIR/KeepAwakeTray.swift"
            KEEP_AWAKE_TRAY_BINARY="$KEEP_AWAKE_INSTALL_DIR/keep-awake-tray"
            KEEP_AWAKE_TRAY_AUTOSTART_FILE="$HOME/Library/LaunchAgents/${KEEP_AWAKE_TRAY_LAUNCH_LABEL}.plist"
            ;;
        wsl2)
            keep_awake::init_windows_paths
            ;;
        *)
            printf 'keep-awake: unsupported host platform: %s\n' "$KEEP_AWAKE_PLATFORM" >&2
            return 1
            ;;
    esac
}

keep_awake::init_windows_paths() {
    local windows_local_appdata
    if ! command -v powershell.exe >/dev/null 2>&1 \
        || ! command -v wslpath >/dev/null 2>&1; then
        printf 'keep-awake: WSL interop requires powershell.exe and wslpath.\n' >&2
        return 1
    fi
    if [ -n "${BOXA_KEEP_AWAKE_INSTALL_DIR:-}" ]; then
        KEEP_AWAKE_INSTALL_DIR="$BOXA_KEEP_AWAKE_INSTALL_DIR"
        KEEP_AWAKE_BINARY="$KEEP_AWAKE_INSTALL_DIR/keep-awake.exe"
        KEEP_AWAKE_WRAPPER="$KEEP_AWAKE_INSTALL_DIR/start-keep-awake.ps1"
        KEEP_AWAKE_WINDOWS_BINARY="$(wslpath -w "$KEEP_AWAKE_BINARY")"
        KEEP_AWAKE_WINDOWS_LOG="$(wslpath -w "$KEEP_AWAKE_LOG_FILE")"
        KEEP_AWAKE_WINDOWS_WRAPPER="$(wslpath -w "$KEEP_AWAKE_WRAPPER")"
        KEEP_AWAKE_TRAY_FILE="$KEEP_AWAKE_INSTALL_DIR/keep-awake-tray.ps1"
        KEEP_AWAKE_WINDOWS_TRAY_FILE="$(wslpath -w "$KEEP_AWAKE_TRAY_FILE")"
        return 0
    fi
    windows_local_appdata="$(powershell.exe -NoProfile -NonInteractive -Command \
        '[Environment]::GetFolderPath("LocalApplicationData")' | tr -d '\r' | tail -n1)"
    if [ -z "$windows_local_appdata" ]; then
        printf 'keep-awake: could not resolve Windows LocalAppData.\n' >&2
        return 1
    fi
    KEEP_AWAKE_INSTALL_DIR="$(wslpath -u "${windows_local_appdata}\\Boxa")"
    KEEP_AWAKE_BINARY="$KEEP_AWAKE_INSTALL_DIR/keep-awake.exe"
    KEEP_AWAKE_WRAPPER="$KEEP_AWAKE_INSTALL_DIR/start-keep-awake.ps1"
    KEEP_AWAKE_WINDOWS_BINARY="${windows_local_appdata}\\Boxa\\keep-awake.exe"
    KEEP_AWAKE_WINDOWS_LOG="${windows_local_appdata}\\Boxa\\keep-awake.log"
    KEEP_AWAKE_WINDOWS_WRAPPER="${windows_local_appdata}\\Boxa\\start-keep-awake.ps1"
    KEEP_AWAKE_TRAY_FILE="$KEEP_AWAKE_INSTALL_DIR/keep-awake-tray.ps1"
    KEEP_AWAKE_WINDOWS_TRAY_FILE="${windows_local_appdata}\\Boxa\\keep-awake-tray.ps1"
}

keep_awake::firewall_rule_present() {
    [ "$KEEP_AWAKE_PLATFORM" = wsl2 ] || return 1
    powershell.exe -NoProfile -NonInteractive -Command \
        "if (Get-NetFirewallRule -Name '$KEEP_AWAKE_FIREWALL_RULE_NAME' -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }" \
        >/dev/null 2>&1
}

keep_awake::run_elevated_powershell() {
    local inner="$1" encoded_inner outer encoded_outer rc=0
    command -v iconv >/dev/null 2>&1 && command -v base64 >/dev/null 2>&1 \
        || return 127
    encoded_inner="$(printf '%s' "$inner" | iconv -t UTF-16LE | base64 -w0)"
    outer="try { \$p = Start-Process powershell -Verb RunAs -Wait -PassThru -ErrorAction Stop -ArgumentList '-NoProfile','-EncodedCommand','${encoded_inner}'; exit \$p.ExitCode } catch [System.ComponentModel.Win32Exception] { if (\$_.Exception.NativeErrorCode -eq 1223) { exit 3 } exit 1 } catch { exit 1 }"
    encoded_outer="$(printf '%s' "$outer" | iconv -t UTF-16LE | base64 -w0)"
    powershell.exe -NoProfile -EncodedCommand "$encoded_outer" >/dev/null 2>&1 || rc=$?
    return "$rc"
}

keep_awake::ensure_firewall_rule() {
    local ps_cmd rc=0
    [ "$KEEP_AWAKE_PLATFORM" = wsl2 ] || return 0
    keep_awake::firewall_rule_present && return 0
    ps_cmd="$(cat <<EOF
\$ErrorActionPreference = 'Stop'
if (-not (Get-NetFirewallRule -Name '$KEEP_AWAKE_FIREWALL_RULE_NAME' -ErrorAction SilentlyContinue)) {
    \$interfaces = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { \$_.InterfaceAlias -like 'vEthernet (WSL*' } |
        Select-Object -ExpandProperty InterfaceAlias -Unique)
    if (\$interfaces.Count -eq 0) { exit 4 }
    New-NetFirewallRule -Name '$KEEP_AWAKE_FIREWALL_RULE_NAME' -DisplayName '$KEEP_AWAKE_FIREWALL_RULE_DISPLAY_NAME' -Description 'Allow Boxa keep-awake from the WSL virtual subnet.' -Enabled True -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort '$KEEP_AWAKE_PORT' -InterfaceAlias \$interfaces -RemoteAddress LocalSubnet | Out-Null
}
EOF
)"
    printf 'keep-awake: installing Windows firewall rule "%s" (UAC will prompt).\n' \
        "$KEEP_AWAKE_FIREWALL_RULE_DISPLAY_NAME" >&2
    keep_awake::run_elevated_powershell "$ps_cmd" || rc=$?
    if [ "$rc" -eq 0 ] && keep_awake::firewall_rule_present; then
        return 0
    fi
    case "$rc" in
        3)
            printf 'keep-awake: WARNING: Windows firewall elevation was declined; the WSL NAT path to TCP port %s stays blocked. Mirrored networking/loopback keeps working.\n' \
                "$KEEP_AWAKE_PORT" >&2
            ;;
        4)
            printf 'keep-awake: WARNING: the WSL vEthernet interface was not found; Windows firewall rule "%s" was not created and the NAT path stays blocked.\n' \
                "$KEEP_AWAKE_FIREWALL_RULE_DISPLAY_NAME" >&2
            ;;
        127)
            printf 'keep-awake: WARNING: iconv/base64 are unavailable; Windows firewall rule "%s" was not created and the NAT path stays blocked.\n' \
                "$KEEP_AWAKE_FIREWALL_RULE_DISPLAY_NAME" >&2
            ;;
        *)
            printf 'keep-awake: WARNING: Windows firewall rule "%s" could not be created (exit %s); the WSL NAT path stays blocked. Mirrored networking/loopback keeps working.\n' \
                "$KEEP_AWAKE_FIREWALL_RULE_DISPLAY_NAME" "$rc" >&2
            ;;
    esac
    return 1
}

# Self-heal seam for callers that have already found the daemon unreachable.
# Deliberately does nothing on its own initiative: an unreachable daemon is the
# only situation in which the rule matters, so healthy hosts never pay for the
# interop calls below and never see an unprompted UAC dialog. Requires evidence
# that the daemon really is running — elevating to unblock a port nothing
# listens on would prompt the user for nothing.
keep_awake::heal_firewall_rule() {
    # Harnesses that exercise the relay against mock daemons run against the
    # real user state; this opt-out keeps them from raising a UAC dialog on the
    # developer's machine.
    [ -z "${BOXA_KEEP_AWAKE_SKIP_FIREWALL_HEAL:-}" ] || return 1
    keep_awake::init_paths || return 1
    [ "$KEEP_AWAKE_PLATFORM" = wsl2 ] || return 1
    [ "$(keep_awake::state_field enabled 2>/dev/null || true)" = true ] || return 1
    keep_awake::firewall_rule_present && return 1
    keep_awake::daemon_running || return 1
    keep_awake::ensure_firewall_rule || return 1
    printf 'keep-awake: installed the missing Windows firewall rule "%s"; retrying the daemon.\n' \
        "$KEEP_AWAKE_FIREWALL_RULE_DISPLAY_NAME" >&2
}

keep_awake::remove_firewall_rule() {
    local ps_cmd rc=0
    [ "$KEEP_AWAKE_PLATFORM" = wsl2 ] || return 0
    keep_awake::firewall_rule_present || return 0
    ps_cmd="\$ErrorActionPreference = 'Stop'; Get-NetFirewallRule -Name '$KEEP_AWAKE_FIREWALL_RULE_NAME' -ErrorAction SilentlyContinue | Remove-NetFirewallRule"
    printf 'keep-awake: removing Windows firewall rule "%s" (UAC will prompt).\n' \
        "$KEEP_AWAKE_FIREWALL_RULE_DISPLAY_NAME" >&2
    keep_awake::run_elevated_powershell "$ps_cmd" || rc=$?
    if [ "$rc" -eq 0 ] && ! keep_awake::firewall_rule_present; then
        return 0
    fi
    printf 'keep-awake: WARNING: Windows firewall rule "%s" could not be removed (exit %s); remove it manually if it remains.\n' \
        "$KEEP_AWAKE_FIREWALL_RULE_DISPLAY_NAME" "$rc" >&2
    return 1
}

keep_awake::daemon_running() {
    case "$KEEP_AWAKE_PLATFORM" in
        wsl2)
            powershell.exe -NoProfile -NonInteractive -Command \
                "if (Get-CimInstance Win32_Process -Filter \"Name='keep-awake.exe'\" -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }" \
                >/dev/null 2>&1
            ;;
        *)
            [ -x "$KEEP_AWAKE_BINARY" ] && pgrep -f "$KEEP_AWAKE_BINARY" >/dev/null 2>&1
            ;;
    esac
}

keep_awake::state_field() {
    local field="$1"
    [ -f "$KEEP_AWAKE_STATE_FILE" ] || return 1
    awk -F= -v key="$field" '$1 == key { print substr($0, index($0, "=") + 1); exit }' \
        "$KEEP_AWAKE_STATE_FILE"
}

keep_awake::write_state() {
    local enabled="$1" optout="$2" autostart="${3:-system}" connection="${4:-ok}" tmp
    mkdir -p "$KEEP_AWAKE_CONFIG_DIR" || return 1
    tmp="${KEEP_AWAKE_STATE_FILE}.tmp.$$"
    if ! printf 'enabled=%s\noptout=%s\nautostart=%s\nconnection=%s\n' \
        "$enabled" "$optout" "$autostart" "$connection" > "$tmp" \
        || ! chmod 0600 "$tmp" \
        || ! mv "$tmp" "$KEEP_AWAKE_STATE_FILE"; then
        rm -f "$tmp"
        return 1
    fi
}

keep_awake::autostart_mode() {
    local mode
    mode="$(keep_awake::state_field autostart 2>/dev/null || true)"
    case "$mode" in
        system|terminal|none) printf '%s\n' "$mode" ;;
        *) printf 'system\n' ;;
    esac
}

keep_awake::host_connection_present() {
    [ -f "$KEEP_AWAKE_CONNECT_FILE" ] || return 1
    awk -F '\t' -v port="$KEEP_AWAKE_PORT" \
        '$1 == "keep-awake" && $2 == "host" && $3 == port && $4 == port { found=1 }
         END { exit found ? 0 : 1 }' "$KEEP_AWAKE_CONNECT_FILE"
}

keep_awake::daemon_url() {
    keep_awake_probe::select_target "$KEEP_AWAKE_PLATFORM" "$KEEP_AWAKE_PORT" \
        || return 1
    printf 'http://%s:%s/v1/status\n' \
        "$KEEP_AWAKE_PROBE_TARGET_ADDRESS" "$KEEP_AWAKE_PORT"
}

keep_awake::daemon_status_json() {
    keep_awake_probe::select_target "$KEEP_AWAKE_PLATFORM" "$KEEP_AWAKE_PORT" \
        || return 1
    keep_awake_probe::status_json
}

keep_awake::relay_target_description() {
    local target_kind target_address
    if [ -f "$KEEP_AWAKE_RELAY_STATE_FILE" ]; then
        target_kind="$(awk -F '\t' 'NR == 1 { print $5 }' \
            "$KEEP_AWAKE_RELAY_STATE_FILE")"
        target_address="$(awk -F '\t' 'NR == 1 { print $6 }' \
            "$KEEP_AWAKE_RELAY_STATE_FILE")"
        if [ -n "$target_kind" ] && [ -n "$target_address" ]; then
            printf '%s (%s)\n' "$target_kind" "$target_address"
            return 0
        fi
    fi
    keep_awake_probe::target_description
}

keep_awake::client_signal_status() {
    local daemon="$1"
    local -a missing=()
    local settings="$KEEP_AWAKE_CLAUDE_DEFAULTS/settings.json"
    local hook="$KEEP_AWAKE_CLAUDE_DEFAULTS/hooks/agent-awake.sh"

    [ -f "$hook" ] || missing+=("managed hook file")
    if [ ! -f "$settings" ]; then
        missing+=("managed settings file")
    elif ! jq -e '
        def has_hook($event; $command):
            any(.hooks[$event][]?.hooks[]?;
                .type == "command" and .command == $command);
        has_hook("UserPromptSubmit"; "~/.claude/hooks/agent-awake.sh busy")
        and has_hook("PreToolUse"; "~/.claude/hooks/agent-awake.sh busy")
        and has_hook("Stop"; "~/.claude/hooks/agent-awake.sh idle")
    ' "$settings" >/dev/null 2>&1; then
        missing+=("managed settings entries")
    fi
    [ "$daemon" = yes ] || missing+=("reachable daemon")

    if [ "${#missing[@]}" -eq 0 ]; then
        printf 'signal path OK\n'
    else
        local joined
        joined="$(IFS=', '; printf '%s' "${missing[*]}")"
        printf 'missing %s\n' "$joined"
    fi
}

keep_awake::autostart_installed() {
    case "$KEEP_AWAKE_PLATFORM" in
        linux)
            [ -f "$KEEP_AWAKE_AUTOSTART_FILE" ] \
                && systemctl --user is-enabled boxa-keep-awake.service >/dev/null 2>&1
            ;;
        macos)
            [ -f "$KEEP_AWAKE_AUTOSTART_FILE" ] \
                && launchctl print "gui/$(id -u)/$KEEP_AWAKE_LAUNCH_LABEL" >/dev/null 2>&1
            ;;
        wsl2)
            schtasks.exe /Query /TN "$KEEP_AWAKE_TASK_NAME" >/dev/null 2>&1 || return 1
            if [ ! -f "$KEEP_AWAKE_WRAPPER" ]; then
                printf 'keep-awake: Windows scheduled task exists, but its PowerShell wrapper is missing at %s. Repair with: boxa keep-awake enable\n' \
                    "$KEEP_AWAKE_WRAPPER" >&2
                return 1
            fi
            ;;
    esac
}

keep_awake::probe() {
    local autostart_mode
    keep_awake::init_paths || { printf 'missing\n'; return 0; }
    autostart_mode="$(keep_awake::autostart_mode)"
    if [ "$(keep_awake::state_field optout 2>/dev/null || true)" = true ]; then
        printf 'declined\n'
    elif [ "$(keep_awake::state_field enabled 2>/dev/null || true)" = true ] \
        && [ -x "$KEEP_AWAKE_BINARY" ] \
        && { [ "$autostart_mode" != system ] || keep_awake::autostart_installed; } \
        && keep_awake::host_connection_present \
        && [ "$(keep_awake::state_field connection 2>/dev/null || true)" != incomplete ] \
        && keep_awake::daemon_status_json >/dev/null; then
        printf 'ok\n'
    else
        printf 'missing\n'
    fi
}

keep_awake::go_remedy() {
    local platform manager
    platform="$(keep_awake::platform 2>/dev/null || true)"
    case "$platform" in
        macos)
            printf 'Have Docker installed and running. Local fallback: Run: brew install go'
            ;;
        linux|wsl2)
            manager=""
            for manager in apt-get dnf pacman zypper apk; do
                command -v "$manager" >/dev/null 2>&1 && break
                manager=""
            done
            case "$manager" in
                apt-get) printf 'Have Docker installed and running. Local fallback: Run: sudo apt-get install -y golang-go' ;;
                dnf)     printf 'Have Docker installed and running. Local fallback: Run: sudo dnf install -y golang' ;;
                pacman)  printf 'Have Docker installed and running. Local fallback: Run: sudo pacman -S go' ;;
                zypper)  printf 'Have Docker installed and running. Local fallback: Run: sudo zypper install -y go' ;;
                apk)     printf 'Have Docker installed and running. Local fallback: Run: sudo apk add go' ;;
                *)       printf 'Have Docker installed and running. Local fallback: install Go from https://go.dev/doc/install' ;;
            esac
            ;;
        *)
            printf 'Have Docker installed and running. Local fallback: install Go from https://go.dev/doc/install'
            ;;
    esac
}

keep_awake::go_prereq() {
    keep_awake::init_paths >/dev/null 2>&1 || return 1
    [ -x "$KEEP_AWAKE_BINARY" ] \
        || command -v docker >/dev/null 2>&1 \
        || command -v go >/dev/null 2>&1
}

keep_awake::check_enable_prereqs() {
    local autostart_mode="$1"
    keep_awake::init_paths || return 1
    if [ ! -x "$KEEP_AWAKE_BINARY" ] \
        && ! command -v docker >/dev/null 2>&1 \
        && ! command -v go >/dev/null 2>&1; then
        printf 'keep-awake: Docker and local Go fallback not found. %s\n' \
            "$(keep_awake::go_remedy)" >&2
        return 1
    fi
    command -v curl >/dev/null 2>&1 || {
        printf 'keep-awake: curl is required to verify the daemon.\n' >&2
        return 1
    }
    [ -x "$KEEP_AWAKE_BOXA" ] || {
        printf 'keep-awake: boxa CLI not executable at %s.\n' "$KEEP_AWAKE_BOXA" >&2
        return 1
    }
    case "$KEEP_AWAKE_PLATFORM" in
        linux)
            [ "$autostart_mode" != system ] || command -v systemctl >/dev/null 2>&1 || {
                printf 'keep-awake: systemctl is required for Linux user autostart.\n' >&2; return 1;
            }
            ;;
        macos)
            [ "$autostart_mode" != system ] || command -v launchctl >/dev/null 2>&1 || {
                printf 'keep-awake: launchctl is required for macOS user autostart.\n' >&2; return 1;
            }
            ;;
        wsl2)
            if ! command -v powershell.exe >/dev/null 2>&1 \
                || ! command -v wslpath >/dev/null 2>&1 \
                || { [ "$autostart_mode" = system ] && ! command -v schtasks.exe >/dev/null 2>&1; }; then
                    printf 'keep-awake: WSL interop prerequisites are missing for the selected autostart mode.\n' >&2
                    return 1
            fi
            ;;
    esac
}

keep_awake::build_binary() {
    local output="$1" output_dir output_name
    local -a docker_args go_args
    output_dir="$(dirname "$output")"
    output_name="$(basename "$output")"

    if command -v docker >/dev/null 2>&1; then
        docker_args=(
            run --rm
            --user "$(id -u):$(id -g)"
            --env CGO_ENABLED=0
            --env GOCACHE=/tmp/gocache
            --env GOMODCACHE=/tmp/gomodcache
        )
        if [ "$KEEP_AWAKE_PLATFORM" = wsl2 ]; then
            docker_args+=(--env GOOS=windows)
        fi
        go_args=(go build -trimpath)
        if [ "$KEEP_AWAKE_PLATFORM" = wsl2 ]; then
            go_args+=(-ldflags -H=windowsgui)
        fi
        go_args+=(-o "/out/$output_name" .)
        docker_args+=(
            --volume "$BOXA_DIR/keep-awake:/src:ro"
            --volume "$output_dir:/out"
            --workdir /src
            "$KEEP_AWAKE_GO_IMAGE"
            "${go_args[@]}"
        )
        if docker "${docker_args[@]}"; then
            return 0
        fi
        printf 'keep-awake: Docker build failed; falling back to the local Go toolchain.\n' >&2
    else
        printf 'keep-awake: Docker command not found; falling back to the local Go toolchain.\n' >&2
    fi

    if ! command -v go >/dev/null 2>&1; then
        printf 'keep-awake: local Go fallback unavailable. %s\n' \
            "$(keep_awake::go_remedy)" >&2
        return 1
    fi
    if [ "$KEEP_AWAKE_PLATFORM" = wsl2 ]; then
        (cd "$BOXA_DIR/keep-awake" \
            && CGO_ENABLED=0 GOOS=windows go build -trimpath \
                -ldflags -H=windowsgui -o "$output" .)
    else
        (cd "$BOXA_DIR/keep-awake" && CGO_ENABLED=0 go build -trimpath -o "$output" .)
    fi
}

keep_awake::start_direct() {
    mkdir -p "$KEEP_AWAKE_STATE_DIR"
    case "$KEEP_AWAKE_PLATFORM" in
        linux|macos)
            "$KEEP_AWAKE_BINARY" -port "$KEEP_AWAKE_PORT" \
                -log-file "$KEEP_AWAKE_LOG_FILE" >/dev/null 2>&1 &
            ;;
        wsl2)
            keep_awake::write_windows_wrapper || return 1
            powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden \
                -File "$KEEP_AWAKE_WINDOWS_WRAPPER" >/dev/null 2>&1 &
            ;;
    esac
}

keep_awake::lua_quote() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '"%s"' "$value"
}

keep_awake::print_terminal_snippet() {
    local binary log wrapper
    binary="$(keep_awake::lua_quote "$KEEP_AWAKE_BINARY")"
    log="$(keep_awake::lua_quote "$KEEP_AWAKE_LOG_FILE")"
    wrapper="$(keep_awake::lua_quote "$KEEP_AWAKE_WINDOWS_WRAPPER")"
    printf '\nAdd this block to wezterm.lua:\n\n'
    if [ "$KEEP_AWAKE_PLATFORM" = wsl2 ]; then
        cat <<EOF
local wezterm = require 'wezterm'

wezterm.on('gui-startup', function()
  wezterm.background_child_process {
    'powershell.exe',
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-WindowStyle', 'Hidden',
    '-File', $wrapper,
    '-TrayFollow', 'wezterm-gui',
  }
end)
EOF
    else
        cat <<EOF
local wezterm = require 'wezterm'

wezterm.on('gui-startup', function()
  wezterm.background_child_process {
    $binary,
    '-port', '$KEEP_AWAKE_PORT',
    '-log-file', $log,
  }
end)
EOF
    fi
}

keep_awake::powershell_literal() {
    local value="$1"
    printf '%s' "${value//\'/\'\'}"
}

keep_awake::write_windows_wrapper() {
    local binary_literal log_literal tray_literal distro_literal
    binary_literal="$(keep_awake::powershell_literal "$KEEP_AWAKE_WINDOWS_BINARY")"
    log_literal="$(keep_awake::powershell_literal "$KEEP_AWAKE_WINDOWS_LOG")"
    tray_literal="$(keep_awake::powershell_literal "$KEEP_AWAKE_WINDOWS_TRAY_FILE")"
    distro_literal="$(keep_awake::powershell_literal "${WSL_DISTRO_NAME:-}")"

    if ! cat > "$KEEP_AWAKE_WRAPPER" <<EOF
param([string]\$TrayFollow = '')
\$binary = '$binary_literal'
\$logFile = '$log_literal'
\$trayFile = '$tray_literal'
\$env:BOXA_WSL_DISTRO = '$distro_literal'
# Terminal mode: the wezterm snippet passes -TrayFollow so the tray starts
# with the terminal and exits with it; the system-mode scheduled task path
# omits it and keeps its own tray task.
if (\$TrayFollow -and (Test-Path -LiteralPath \$trayFile)) {
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden',
        '-ExecutionPolicy', 'Bypass', '-File', ('"' + \$trayFile + '"'),
        '$KEEP_AWAKE_PORT', \$TrayFollow)
}
function Get-WslGateway {
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { \$_.InterfaceAlias -like 'vEthernet (WSL*' -and \$_.IPAddress -notlike '169.254.*' } |
        Select-Object -First 1 -ExpandProperty IPAddress
}
\$gateway = \$null
for (\$attempt = 0; \$attempt -lt 30 -and -not \$gateway; \$attempt++) {
    \$gateway = Get-WslGateway
    if (-not \$gateway) { Start-Sleep -Seconds 2 }
}
\$arguments = @('-port', '$KEEP_AWAKE_PORT', '-log-file', ('"' + \$logFile + '"'))
if (\$gateway) {
    \$arguments += @('-listen-address', \$gateway, '-listen-unsafe')
    & \$binary @arguments
    exit \$LASTEXITCODE
} else {
    Add-Content -LiteralPath \$logFile -Value "\$(Get-Date -Format o) keep-awake: WSL vEthernet adapter unavailable after retries; starting with loopback-only binding."
}
\$daemon = Start-Process -FilePath \$binary -ArgumentList \$arguments -PassThru
while (-not \$daemon.HasExited) {
    Start-Sleep -Seconds 30
    \$gateway = Get-WslGateway
    if (-not \$gateway) { continue }

    Add-Content -LiteralPath \$logFile -Value "\$(Get-Date -Format o) keep-awake: WSL vEthernet adapter appeared at \$gateway; stopping loopback-only daemon PID \$(\$daemon.Id)."
    Stop-Process -Id \$daemon.Id -ErrorAction SilentlyContinue
    \$daemon.WaitForExit()
    Add-Content -LiteralPath \$logFile -Value "\$(Get-Date -Format o) keep-awake: restarting with loopback and vEthernet listeners."
    \$arguments += @('-listen-address', \$gateway, '-listen-unsafe')
    & \$binary @arguments
    exit \$LASTEXITCODE
}
exit \$daemon.ExitCode
EOF
    then
        return 1
    fi
    chmod 0600 "$KEEP_AWAKE_WRAPPER"
}

keep_awake::stop_direct() {
    local binary_literal expected pid
    case "$KEEP_AWAKE_PLATFORM" in
        linux|macos)
            expected="$KEEP_AWAKE_BINARY -port $KEEP_AWAKE_PORT -log-file $KEEP_AWAKE_LOG_FILE"
            while IFS= read -r pid; do
                if [[ "$pid" =~ ^[0-9]+$ ]]; then
                    kill "$pid" 2>/dev/null || true
                fi
            done < <(
                ps -ax -o pid= -o command= 2>/dev/null \
                    | awk -v expected="$expected" '
                        { pid=$1; $1=""; sub(/^ /, "") }
                        $0 == expected { print pid }
                    '
            )
            ;;
        wsl2)
            binary_literal="$(keep_awake::powershell_literal "$KEEP_AWAKE_WINDOWS_BINARY")"
            powershell.exe -NoProfile -NonInteractive -Command \
                "\$binary = '$binary_literal'; Get-CimInstance Win32_Process | Where-Object { \$_.ExecutablePath -eq \$binary } | ForEach-Object { Stop-Process -Id \$_.ProcessId -ErrorAction SilentlyContinue }" \
                >/dev/null 2>&1 || true
            ;;
    esac
}

keep_awake::install_autostart() {
    mkdir -p "$KEEP_AWAKE_STATE_DIR"
    case "$KEEP_AWAKE_PLATFORM" in
        linux)
            mkdir -p "$(dirname "$KEEP_AWAKE_AUTOSTART_FILE")" || return 1
            if ! cat > "$KEEP_AWAKE_AUTOSTART_FILE" <<EOF
[Unit]
Description=Boxa keep-awake daemon
After=default.target

[Service]
ExecStart=$KEEP_AWAKE_BINARY -port $KEEP_AWAKE_PORT -log-file $KEEP_AWAKE_LOG_FILE
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
EOF
            then
                return 1
            fi
            systemctl --user daemon-reload
            systemctl --user enable --now boxa-keep-awake.service
            ;;
        macos)
            mkdir -p "$(dirname "$KEEP_AWAKE_AUTOSTART_FILE")" || return 1
            if ! cat > "$KEEP_AWAKE_AUTOSTART_FILE" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$KEEP_AWAKE_LAUNCH_LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$KEEP_AWAKE_BINARY</string><string>-port</string><string>$KEEP_AWAKE_PORT</string>
    <string>-log-file</string><string>$KEEP_AWAKE_LOG_FILE</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
</dict></plist>
EOF
            then
                return 1
            fi
            launchctl bootout "gui/$(id -u)" "$KEEP_AWAKE_AUTOSTART_FILE" >/dev/null 2>&1 || true
            launchctl bootstrap "gui/$(id -u)" "$KEEP_AWAKE_AUTOSTART_FILE"
            launchctl kickstart -k "gui/$(id -u)/$KEEP_AWAKE_LAUNCH_LABEL"
            ;;
        wsl2)
            local action
            keep_awake::write_windows_wrapper || return 1
            action="powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"$KEEP_AWAKE_WINDOWS_WRAPPER\""
            schtasks.exe /Create /TN "$KEEP_AWAKE_TASK_NAME" /SC ONLOGON /TR "$action" /F >/dev/null
            schtasks.exe /Run /TN "$KEEP_AWAKE_TASK_NAME" >/dev/null
            ;;
    esac
}

keep_awake::remove_autostart() {
    case "$KEEP_AWAKE_PLATFORM" in
        linux)
            systemctl --user disable --now boxa-keep-awake.service >/dev/null 2>&1 || true
            rm -f "$KEEP_AWAKE_AUTOSTART_FILE"
            systemctl --user daemon-reload >/dev/null 2>&1 || true
            ;;
        macos)
            launchctl bootout "gui/$(id -u)" "$KEEP_AWAKE_AUTOSTART_FILE" >/dev/null 2>&1 || true
            rm -f "$KEEP_AWAKE_AUTOSTART_FILE"
            ;;
        wsl2)
            schtasks.exe /End /TN "$KEEP_AWAKE_TASK_NAME" >/dev/null 2>&1 || true
            schtasks.exe /Delete /TN "$KEEP_AWAKE_TASK_NAME" /F >/dev/null 2>&1 || true
            rm -f "$KEEP_AWAKE_WRAPPER"
            ;;
    esac
}

keep_awake::tray::remove() {
    case "$KEEP_AWAKE_PLATFORM" in
        linux)
            systemctl --user disable --now boxa-keep-awake-tray.service >/dev/null 2>&1 || true
            rm -f "$KEEP_AWAKE_TRAY_AUTOSTART_FILE" "$KEEP_AWAKE_TRAY_FILE" \
                "$KEEP_AWAKE_TRAY_BUSY_ICON" "$KEEP_AWAKE_TRAY_IDLE_ICON"
            systemctl --user daemon-reload >/dev/null 2>&1 || true
            ;;
        macos)
            launchctl bootout "gui/$(id -u)" "$KEEP_AWAKE_TRAY_AUTOSTART_FILE" >/dev/null 2>&1 || true
            rm -f "$KEEP_AWAKE_TRAY_AUTOSTART_FILE" "$KEEP_AWAKE_TRAY_FILE" \
                "$KEEP_AWAKE_TRAY_BINARY"
            ;;
        wsl2)
            schtasks.exe /End /TN "$KEEP_AWAKE_TRAY_TASK_NAME" >/dev/null 2>&1 || true
            schtasks.exe /Delete /TN "$KEEP_AWAKE_TRAY_TASK_NAME" /F >/dev/null 2>&1 || true
            # Terminal mode has no scheduled task; stop a wrapper-spawned tray too.
            powershell.exe -NoProfile -NonInteractive -Command \
                "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { \$_.ProcessId -ne \$PID -and \$_.CommandLine -like '*keep-awake-tray.ps1*' } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force }" \
                >/dev/null 2>&1 || true
            rm -f "$KEEP_AWAKE_TRAY_FILE"
            ;;
    esac
}

# Terminal-mode tray (wsl2 only): install the script without a scheduled task
# and best-effort start it now — the running WezTerm already missed its
# gui-startup, so the first icon should not wait for the next launch.
keep_awake::tray::enable_terminal() {
    [ "$KEEP_AWAKE_PLATFORM" = wsl2 ] || return 0
    if ! install -m 0600 "$BOXA_DIR/keep-awake/tray/keep-awake-tray.ps1" "$KEEP_AWAKE_TRAY_FILE"; then
        printf 'keep-awake: tray installation failed; daemon remains enabled without the optional tray.\n' >&2
        return 0
    fi
    if ! powershell.exe -NoProfile -NonInteractive -Command \
        "Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @('-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', '\"$(keep_awake::powershell_literal "$KEEP_AWAKE_WINDOWS_TRAY_FILE")\"', '$KEEP_AWAKE_PORT', 'wezterm-gui')" \
        >/dev/null 2>&1; then
        printf 'keep-awake: tray start failed; it will start with the next WezTerm launch.\n' >&2
    fi
    return 0
}

keep_awake::tray::install_linux() {
    mkdir -p "$(dirname "$KEEP_AWAKE_TRAY_AUTOSTART_FILE")" || return 1
    install -m 0755 "$BOXA_DIR/keep-awake/tray/keep-awake-tray.sh" "$KEEP_AWAKE_TRAY_FILE" \
        || return 1
    install -m 0644 "$BOXA_DIR/keep-awake/tray/busy.svg" "$KEEP_AWAKE_TRAY_BUSY_ICON" \
        || return 1
    install -m 0644 "$BOXA_DIR/keep-awake/tray/idle.svg" "$KEEP_AWAKE_TRAY_IDLE_ICON" \
        || return 1
    if ! cat > "$KEEP_AWAKE_TRAY_AUTOSTART_FILE" <<EOF
[Unit]
Description=Boxa keep-awake tray indicator
After=graphical-session.target

[Service]
ExecStart=$KEEP_AWAKE_TRAY_FILE $KEEP_AWAKE_PORT $KEEP_AWAKE_INSTALL_DIR
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
EOF
    then
        return 1
    fi
    systemctl --user daemon-reload \
        && systemctl --user enable --now boxa-keep-awake-tray.service
}

keep_awake::tray::install_macos() {
    install -m 0644 "$BOXA_DIR/keep-awake/tray/KeepAwakeTray.swift" "$KEEP_AWAKE_TRAY_FILE" \
        || return 1
    swiftc "$KEEP_AWAKE_TRAY_FILE" -framework AppKit -framework Foundation \
        -o "$KEEP_AWAKE_TRAY_BINARY" || return 1
    chmod 0755 "$KEEP_AWAKE_TRAY_BINARY" || return 1
    mkdir -p "$(dirname "$KEEP_AWAKE_TRAY_AUTOSTART_FILE")" || return 1
    if ! cat > "$KEEP_AWAKE_TRAY_AUTOSTART_FILE" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$KEEP_AWAKE_TRAY_LAUNCH_LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$KEEP_AWAKE_TRAY_BINARY</string><string>$KEEP_AWAKE_PORT</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
</dict></plist>
EOF
    then
        return 1
    fi
    launchctl bootout "gui/$(id -u)" "$KEEP_AWAKE_TRAY_AUTOSTART_FILE" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/$(id -u)" "$KEEP_AWAKE_TRAY_AUTOSTART_FILE" \
        && launchctl kickstart -k "gui/$(id -u)/$KEEP_AWAKE_TRAY_LAUNCH_LABEL"
}

keep_awake::tray::install_windows() {
    local action
    install -m 0600 "$BOXA_DIR/keep-awake/tray/keep-awake-tray.ps1" "$KEEP_AWAKE_TRAY_FILE" \
        || return 1
    action="powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File \"$KEEP_AWAKE_WINDOWS_TRAY_FILE\" $KEEP_AWAKE_PORT"
    schtasks.exe /Create /TN "$KEEP_AWAKE_TRAY_TASK_NAME" /SC ONLOGON /TR "$action" /F >/dev/null \
        && schtasks.exe /Run /TN "$KEEP_AWAKE_TRAY_TASK_NAME" >/dev/null
}

keep_awake::tray::enable() {
    case "$KEEP_AWAKE_PLATFORM" in
        linux)
            if ! command -v yad >/dev/null 2>&1; then
                printf 'keep-awake: tray skipped; yad is missing. Install the yad package to enable it.\n' >&2
                return 0
            fi
            if keep_awake::tray::install_linux; then return 0; fi
            ;;
        macos)
            if ! command -v swiftc >/dev/null 2>&1; then
                printf 'keep-awake: tray skipped; swiftc is missing. Run: xcode-select --install\n' >&2
                return 0
            fi
            if keep_awake::tray::install_macos; then return 0; fi
            ;;
        wsl2)
            if keep_awake::tray::install_windows; then return 0; fi
            ;;
    esac
    printf 'keep-awake: tray installation failed; daemon remains enabled without the optional tray.\n' >&2
    keep_awake::tray::remove >/dev/null 2>&1 || true
    return 0
}

keep_awake::tray::status() {
    case "$KEEP_AWAKE_PLATFORM" in
        linux)
            if [ -f "$KEEP_AWAKE_TRAY_FILE" ] \
                && [ -f "$KEEP_AWAKE_TRAY_AUTOSTART_FILE" ] \
                && systemctl --user is-active boxa-keep-awake-tray.service >/dev/null 2>&1; then
                printf 'running\n'
            elif ! command -v yad >/dev/null 2>&1; then
                printf 'skipped-missing-prereq\n'
            else
                printf 'not installed\n'
            fi
            ;;
        macos)
            if [ -x "$KEEP_AWAKE_TRAY_BINARY" ] \
                && [ -f "$KEEP_AWAKE_TRAY_AUTOSTART_FILE" ] \
                && launchctl print "gui/$(id -u)/$KEEP_AWAKE_TRAY_LAUNCH_LABEL" 2>/dev/null \
                    | grep -q 'state = running'; then
                printf 'running\n'
            elif ! command -v swiftc >/dev/null 2>&1; then
                printf 'skipped-missing-prereq\n'
            else
                printf 'not installed\n'
            fi
            ;;
        wsl2)
            if [ -f "$KEEP_AWAKE_TRAY_FILE" ] \
                && powershell.exe -NoProfile -NonInteractive -Command \
                    "if ((Get-ScheduledTask -TaskName '$KEEP_AWAKE_TRAY_TASK_NAME' -ErrorAction SilentlyContinue).State -eq 'Running') { exit 0 } else { exit 1 }" \
                    >/dev/null 2>&1; then
                printf 'running\n'
            elif [ -f "$KEEP_AWAKE_TRAY_FILE" ] \
                && powershell.exe -NoProfile -NonInteractive -Command \
                    "if (Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { \$_.ProcessId -ne \$PID -and \$_.CommandLine -like '*keep-awake-tray.ps1*' }) { exit 0 } else { exit 1 }" \
                    >/dev/null 2>&1; then
                printf 'running\n'
            else
                printf 'not installed\n'
            fi
            ;;
    esac
}

keep_awake::remove_host_connection() {
    if keep_awake::host_connection_present; then
        "$KEEP_AWAKE_BOXA" connect rm host "$KEEP_AWAKE_PORT" --all
    fi
}

keep_awake::rollback() {
    keep_awake::remove_host_connection >/dev/null 2>&1 || true
    keep_awake::remove_firewall_rule >/dev/null 2>&1 || true
    keep_awake::tray::remove >/dev/null 2>&1 || true
    keep_awake::remove_autostart
    keep_awake::stop_direct
    rm -f "$KEEP_AWAKE_BINARY"
}

keep_awake::wait_until_reachable() {
    local remaining=10
    while [ "$remaining" -gt 0 ]; do
        keep_awake::daemon_status_json >/dev/null && return 0
        sleep 0.2
        remaining=$((remaining - 1))
    done
    return 1
}

keep_awake::enable() {
    local autostart_mode=system tmp_dir="" built_binary=""
    local firewall_rule_ready=true daemon_reachable=true
    if [ "$#" -gt 0 ]; then
        if [ "$#" -ne 2 ] || [ "$1" != --autostart ]; then
            printf 'keep-awake enable: expected --autostart <system|terminal|none>\n' >&2
            return 2
        fi
        autostart_mode="$2"
    fi
    case "$autostart_mode" in
        system|terminal|none) ;;
        *) printf 'keep-awake enable: invalid autostart mode: %s\n' "$autostart_mode" >&2; return 2 ;;
    esac
    keep_awake::check_enable_prereqs "$autostart_mode" || return 1

    if [ ! -x "$KEEP_AWAKE_BINARY" ]; then
        tmp_dir="$(mktemp -d)"
        built_binary="$tmp_dir/$(basename "$KEEP_AWAKE_BINARY")"
        if ! keep_awake::build_binary "$built_binary"; then
            rm -rf "$tmp_dir"
            printf 'keep-awake: binary build failed; no host state was changed.\n' >&2
            return 1
        fi
        if ! mkdir -p "$KEEP_AWAKE_INSTALL_DIR" \
            || ! install -m 0755 "$built_binary" "$KEEP_AWAKE_BINARY"; then
            rm -rf "$tmp_dir"
            rm -f "$KEEP_AWAKE_BINARY"
            printf 'keep-awake: binary installation failed; no host state was changed.\n' >&2
            return 1
        fi
        rm -rf "$tmp_dir"
    fi

    if [ "$autostart_mode" = system ]; then
        if ! keep_awake::install_autostart; then
            keep_awake::rollback
            printf 'keep-awake: autostart installation failed; rolled back.\n' >&2
            return 1
        fi
    else
        keep_awake::tray::remove >/dev/null 2>&1 || true
        keep_awake::remove_autostart
        if ! keep_awake::start_direct; then
            keep_awake::rollback
            printf 'keep-awake: daemon start failed; rolled back.\n' >&2
            return 1
        fi
    fi
    if [ "$KEEP_AWAKE_PLATFORM" = wsl2 ] \
        && ! keep_awake::ensure_firewall_rule; then
        firewall_rule_ready=false
    fi
    if ! keep_awake::wait_until_reachable; then
        if [ "$KEEP_AWAKE_PLATFORM" = wsl2 ] && [ "$firewall_rule_ready" = false ]; then
            daemon_reachable=false
            printf 'keep-awake: WARNING: daemon reachability could not be verified while the Windows firewall rule is absent; enable will continue so mirrored/loopback operation remains available.\n' >&2
        else
            keep_awake::rollback
            printf 'keep-awake: daemon did not become reachable; rolled back.\n' >&2
            return 1
        fi
    fi
    # A connection failure (typically one stale box refusing the firewall
    # slot) must NOT tear down a working daemon: keep everything installed,
    # record state, and let a re-run of enable retry the connection.
    local host_connection_active=true connection_state=ok
    "$KEEP_AWAKE_BOXA" connect host "$KEEP_AWAKE_PORT" "$KEEP_AWAKE_PORT" \
        --name keep-awake --all || { host_connection_active=false; connection_state=incomplete; }
    if ! keep_awake::write_state true false "$autostart_mode" "$connection_state"; then
        keep_awake::rollback
        printf 'keep-awake: could not record enabled state; rolled back.\n' >&2
        return 1
    fi
    local connection_summary="Host connection active on port $KEEP_AWAKE_PORT"
    if [ "$host_connection_active" = false ]; then
        connection_summary="Host connection INCOMPLETE (see errors above)"
    fi
    if [ "$autostart_mode" = system ]; then
        # A leftover terminal-mode tray would hold the single-instance mutex
        # and starve the scheduled-task tray; clear it before installing.
        keep_awake::tray::remove >/dev/null 2>&1 || true
        keep_awake::tray::enable
        printf 'Keep-awake enabled: daemon running, autostart installed, %s.\n' \
            "$connection_summary"
    else
        if [ "$autostart_mode" = terminal ]; then
            keep_awake::tray::enable_terminal
        fi
        printf 'Keep-awake enabled: daemon running, autostart %s, %s.\n' \
            "$autostart_mode" "$connection_summary"
        if [ "$autostart_mode" = terminal ]; then
            keep_awake::print_terminal_snippet
        fi
    fi
    if [ "$host_connection_active" = false ]; then
        printf 'keep-awake: Host connection failed in at least one box; daemon, autostart, and tray stay installed.\n' >&2
        printf 'keep-awake: fix the reported boxes, then re-run "boxa keep-awake enable" to retry the connection.\n' >&2
        if [ "$KEEP_AWAKE_PLATFORM" = wsl2 ] \
            && [ "$firewall_rule_ready" = false ] \
            && [ "$daemon_reachable" = false ]; then
            return 0
        fi
        return 1
    fi
}

keep_awake::refresh() {
    local autostart_mode tmp_dir built_binary stopped_for_swap=false
    keep_awake::init_paths || return 1
    [ "$(keep_awake::state_field enabled 2>/dev/null || true)" = true ] || return 0

    autostart_mode="$(keep_awake::autostart_mode)"
    tmp_dir="$(mktemp -d)"
    built_binary="$tmp_dir/$(basename "$KEEP_AWAKE_BINARY")"
    if ! keep_awake::build_binary "$built_binary"; then
        rm -rf "$tmp_dir"
        printf 'keep-awake: binary refresh build failed; installed daemon was not changed.\n' >&2
        return 1
    fi

    # Windows cannot replace a running executable. Unix can replace in place,
    # avoiding a service-manager restart race until the new file is complete.
    if [ "$KEEP_AWAKE_PLATFORM" = wsl2 ]; then
        keep_awake::stop_direct
        stopped_for_swap=true
    fi
    if ! mkdir -p "$KEEP_AWAKE_INSTALL_DIR" \
        || ! install -m 0755 "$built_binary" "$KEEP_AWAKE_BINARY"; then
        rm -rf "$tmp_dir"
        printf 'keep-awake: refreshed binary installation failed.\n' >&2
        # The Windows stop above already took the daemon down while the old
        # binary is still installed untouched: restart that old binary instead
        # of leaving the host daemon-less until someone intervenes by hand.
        if [ "$stopped_for_swap" = true ]; then
            case "$autostart_mode" in
                system)
                    schtasks.exe /Run /TN "$KEEP_AWAKE_TASK_NAME" >/dev/null 2>&1 || true
                    ;;
                terminal) keep_awake::start_direct || true ;;
                none)
                    printf 'keep-awake: the user-managed daemon was stopped for the Windows binary swap; start it again with your own mechanism.\n' >&2
                    ;;
            esac
        fi
        return 1
    fi
    rm -rf "$tmp_dir"

    # In "none" mode the daemon belongs to the user's own start mechanism and
    # may run with arguments boxa never chose. Taking ownership here would risk
    # missing that process on stop and racing a competing default instance onto
    # the port, so refresh only swaps the file and reports what is left to do.
    case "$autostart_mode" in
        system)
            case "$KEEP_AWAKE_PLATFORM" in
                linux) systemctl --user restart boxa-keep-awake.service ;;
                macos) launchctl kickstart -k "gui/$(id -u)/$KEEP_AWAKE_LAUNCH_LABEL" ;;
                wsl2)
                    schtasks.exe /End /TN "$KEEP_AWAKE_TASK_NAME" >/dev/null 2>&1 || true
                    schtasks.exe /Run /TN "$KEEP_AWAKE_TASK_NAME" >/dev/null
                    ;;
            esac
            printf 'keep-awake: daemon binary refreshed and restarted.\n'
            ;;
        none)
            if [ "$stopped_for_swap" = true ]; then
                printf 'keep-awake: refreshed binary installed; the user-managed daemon was stopped for the Windows binary swap — start it again with your own mechanism.\n'
            else
                # The running process keeps the old inode until it exits; the
                # next user-managed start picks up the refreshed binary.
                printf 'keep-awake: refreshed binary installed; restart the user-managed daemon with your own mechanism to pick it up.\n'
            fi
            ;;
        *)
            [ "$KEEP_AWAKE_PLATFORM" = wsl2 ] || keep_awake::stop_direct
            keep_awake::start_direct
            printf 'keep-awake: daemon binary refreshed and restarted.\n'
            ;;
    esac
}

keep_awake::teardown() {
    local keep_connection=false remove_state=false arg autostart_mode rc=0
    for arg in "$@"; do
        case "$arg" in
            --keep-connection) keep_connection=true ;;
            --remove-state) remove_state=true ;;
            *) printf 'keep-awake teardown: unknown option %s\n' "$arg" >&2; return 2 ;;
        esac
    done
    keep_awake::init_paths || return 1
    autostart_mode="$(keep_awake::autostart_mode)"
    if ! $keep_connection; then
        keep_awake::remove_host_connection || rc=1
    fi
    keep_awake::remove_firewall_rule || true
    keep_awake::tray::remove || rc=1
    keep_awake::remove_autostart
    keep_awake::stop_direct
    rm -f "$KEEP_AWAKE_BINARY" || rc=1
    if $remove_state; then
        rm -f "$KEEP_AWAKE_STATE_FILE" || rc=1
    else
        keep_awake::write_state false true "$autostart_mode" || rc=1
    fi
    return "$rc"
}

keep_awake::disable() {
    local autostart_mode
    autostart_mode="$(keep_awake::autostart_mode)"
    keep_awake::teardown
    printf 'Keep-awake disabled: daemon stopped, autostart removed, Host connection removed.\n'
    if [ "$autostart_mode" = terminal ]; then
        printf 'Remove the Boxa keep-awake gui-startup block from wezterm.lua.\n'
    fi
}

keep_awake::status() {
    local status_json="" holders="[]" daemon=no daemon_target=unreachable
    local autostart=no connection=no tray client_signal autostart_mode firewall_rule
    local warm_hook_armed=unknown warm_hook_alive=unknown
    keep_awake::init_paths || return 1
    autostart_mode="$(keep_awake::autostart_mode)"
    if keep_awake_probe::select_target "$KEEP_AWAKE_PLATFORM" "$KEEP_AWAKE_PORT"; then
        daemon=yes
        status_json="$(keep_awake_probe::status_json)"
        daemon_target="$(keep_awake::relay_target_description)"
        holders="$(printf '%s\n' "$status_json" \
            | sed -nE 's/.*"activeHolders":(\[[^]]*]).*/\1/p')"
        [ -n "$holders" ] || holders="[]"
        warm_hook_armed="$(printf '%s\n' "$status_json" \
            | sed -nE 's/.*"warmHookArmed":(true|false).*/\1/p')"
        warm_hook_alive="$(printf '%s\n' "$status_json" \
            | sed -nE 's/.*"warmHookAlive":(true|false).*/\1/p')"
        [ -n "$warm_hook_armed" ] || warm_hook_armed=unknown
        [ -n "$warm_hook_alive" ] || warm_hook_alive=unknown
    fi
    keep_awake::autostart_installed && autostart=yes
    keep_awake::host_connection_present && connection=yes
    if [ "$connection" = yes ] \
        && [ "$(keep_awake::state_field connection 2>/dev/null || true)" = incomplete ]; then
        connection='incomplete (re-run: boxa keep-awake enable)'
    fi
    if [ "$autostart_mode" = system ]; then
        tray="$(keep_awake::tray::status)"
    elif [ "$autostart_mode" = terminal ] && [ "$KEEP_AWAKE_PLATFORM" = wsl2 ]; then
        tray="$(keep_awake::tray::status)"
        if [ "$tray" = "not installed" ]; then
            tray="not running (starts with WezTerm)"
        fi
    else
        tray="not installed (autostart: $autostart_mode)"
    fi
    client_signal="$(keep_awake::client_signal_status "$daemon")"
    printf 'Daemon reachable: %s\n' "$daemon"
    printf 'Relay target: %s\n' "$daemon_target"
    printf 'Holders: %s\n' "$holders"
    printf 'Warm hook: armed=%s, alive=%s\n' "$warm_hook_armed" "$warm_hook_alive"
    printf 'Autostart installed: %s\n' "$autostart"
    printf 'autostart: %s\n' "$autostart_mode"
    printf 'Host connection present: %s\n' "$connection"
    if [ "$KEEP_AWAKE_PLATFORM" = wsl2 ]; then
        if keep_awake::firewall_rule_present; then
            firewall_rule="present ($KEEP_AWAKE_FIREWALL_RULE_DISPLAY_NAME)"
        else
            firewall_rule="absent ($KEEP_AWAKE_FIREWALL_RULE_DISPLAY_NAME)"
        fi
        printf 'Windows firewall rule: %s\n' "$firewall_rule"
        if [ "$daemon" = no ] && ! keep_awake::firewall_rule_present \
            && keep_awake::daemon_running; then
            printf 'Diagnosis: gateway target unreachable while the daemon runs; missing Windows firewall rule "%s" is the likely cause.\n' \
                "$KEEP_AWAKE_FIREWALL_RULE_DISPLAY_NAME"
        fi
    fi
    printf 'Client signal: %s\n' "$client_signal"
    printf 'Tray: %s\n' "$tray"
}

keep_awake::doctor() {
    keep_awake::init_paths || return 0
    [ "$KEEP_AWAKE_PLATFORM" = wsl2 ] || return 0
    [ "$(keep_awake::state_field enabled 2>/dev/null || true)" = true ] || return 0
    keep_awake::status \
        | grep -E '^(Relay target:|Windows firewall rule:|Diagnosis:)'
}

keep_awake::offer() {
    local force_yes=false force_noninteractive=false force_interactive=false arg state answer=""
    for arg in "$@"; do
        case "$arg" in
            --yes) force_yes=true ;;
            --non-interactive) force_noninteractive=true ;;
            --interactive) force_interactive=true ;;
            *) printf 'keep-awake offer: unknown option %s\n' "$arg" >&2; return 2 ;;
        esac
    done
    state="$(keep_awake::probe)"
    [ "$state" = missing ] || return 0
    if $force_yes; then
        keep_awake::enable --autostart system
        return
    fi
    if $force_noninteractive || { ! $force_interactive && { [ ! -t 0 ] || [ ! -t 1 ]; }; }; then
        printf 'Keep-awake is optional. Enable it later with: boxa keep-awake enable\n'
        return 0
    fi
    printf '\nBoxa can keep the host awake while coding agents hold active leases.\n'
    printf 'Enable keep-awake now? [y/N] '
    read -r answer || answer=""
    case "$answer" in
        y|Y|yes|YES) keep_awake::enable --autostart system ;;
        *)
            keep_awake::init_paths
            keep_awake::write_state false true
            printf "Keep-awake declined. Enable it later with 'boxa keep-awake enable'.\n"
            ;;
    esac
}

command_name="${1:-}"
if [ -n "$command_name" ]; then
    shift
fi
case "$command_name" in
    offer)       keep_awake::offer "$@" ;;
    probe)       keep_awake::probe ;;
    enable)      keep_awake::enable "$@" ;;
    refresh)
        [ "$#" -eq 0 ] || { printf 'keep-awake refresh: no options expected\n' >&2; exit 2; }
        keep_awake::refresh
        ;;
    disable)     keep_awake::disable ;;
    status)      keep_awake::status ;;
    doctor)      keep_awake::doctor ;;
    heal-firewall) keep_awake::heal_firewall_rule ;;
    teardown)    keep_awake::teardown "$@" ;;
    go-prereq)   keep_awake::go_prereq ;;
    go-remedy)   keep_awake::go_remedy; printf '\n' ;;
    -h|--help|'') usage ;;
    *) printf 'ensure-keep-awake.sh: unknown command %s\n' "$command_name" >&2; usage >&2; exit 2 ;;
esac
