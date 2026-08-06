#!/usr/bin/env bash
set -euo pipefail

# Canonical lifecycle for the optional keep-awake host daemon. The CLI,
# provisioning registry, installer, and uninstaller all delegate here so the
# binary, platform autostart, and global Host connection converge together.

BOXA_DIR="${BOXA_DIR:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
KEEP_AWAKE_PORT="${BOXA_KEEP_AWAKE_PORT:-17777}"
KEEP_AWAKE_TASK_NAME="BoxaKeepAwake"
KEEP_AWAKE_LAUNCH_LABEL="dev.boxa.keep-awake"
KEEP_AWAKE_TRAY_TASK_NAME="BoxaKeepAwakeTray"
KEEP_AWAKE_TRAY_LAUNCH_LABEL="dev.boxa.keep-awake-tray"
KEEP_AWAKE_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/boxa"
KEEP_AWAKE_STATE_FILE="$KEEP_AWAKE_CONFIG_DIR/keep-awake.conf"
KEEP_AWAKE_CONNECT_FILE="$KEEP_AWAKE_CONFIG_DIR/connect/_all.tsv"
KEEP_AWAKE_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/boxa/keep-awake"
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
Usage: ensure-keep-awake.sh <offer|probe|enable|disable|status|teardown|go-prereq|go-remedy> [options]

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

keep_awake::state_field() {
    local field="$1"
    [ -f "$KEEP_AWAKE_STATE_FILE" ] || return 1
    awk -F= -v key="$field" '$1 == key { print substr($0, index($0, "=") + 1); exit }' \
        "$KEEP_AWAKE_STATE_FILE"
}

keep_awake::write_state() {
    local enabled="$1" optout="$2" autostart="${3:-system}" tmp
    mkdir -p "$KEEP_AWAKE_CONFIG_DIR" || return 1
    tmp="${KEEP_AWAKE_STATE_FILE}.tmp.$$"
    if ! printf 'enabled=%s\noptout=%s\nautostart=%s\n' \
        "$enabled" "$optout" "$autostart" > "$tmp" \
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
    local address="127.0.0.1"
    if [ "$KEEP_AWAKE_PLATFORM" = wsl2 ]; then
        address="$(ip route show default 2>/dev/null | awk 'NR == 1 { print $3; exit }')"
        [ -n "$address" ] || address="127.0.0.1"
    fi
    printf 'http://%s:%s/v1/status\n' "$address" "$KEEP_AWAKE_PORT"
}

keep_awake::daemon_status_json() {
    curl -fsS --max-time 2 "$(keep_awake::daemon_url)" 2>/dev/null
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
    local binary_literal log_literal
    binary_literal="$(keep_awake::powershell_literal "$KEEP_AWAKE_WINDOWS_BINARY")"
    log_literal="$(keep_awake::powershell_literal "$KEEP_AWAKE_WINDOWS_LOG")"

    if ! cat > "$KEEP_AWAKE_WRAPPER" <<EOF
\$binary = '$binary_literal'
\$logFile = '$log_literal'
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
            rm -f "$KEEP_AWAKE_TRAY_FILE"
            ;;
    esac
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
    if ! keep_awake::wait_until_reachable; then
        keep_awake::rollback
        printf 'keep-awake: daemon did not become reachable; rolled back.\n' >&2
        return 1
    fi
    if ! "$KEEP_AWAKE_BOXA" connect host "$KEEP_AWAKE_PORT" "$KEEP_AWAKE_PORT" \
        --name keep-awake --all; then
        keep_awake::rollback
        printf 'keep-awake: Host connection setup failed; rolled back.\n' >&2
        return 1
    fi
    if ! keep_awake::write_state true false "$autostart_mode"; then
        keep_awake::rollback
        printf 'keep-awake: could not record enabled state; rolled back.\n' >&2
        return 1
    fi
    if [ "$autostart_mode" = system ]; then
        keep_awake::tray::enable
        printf 'Keep-awake enabled: daemon running, autostart installed, Host connection active on port %s.\n' \
            "$KEEP_AWAKE_PORT"
    else
        printf 'Keep-awake enabled: daemon running, autostart %s, Host connection active on port %s.\n' \
            "$autostart_mode" "$KEEP_AWAKE_PORT"
        if [ "$autostart_mode" = terminal ]; then
            keep_awake::print_terminal_snippet
        fi
    fi
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
    local status_json="" holders="[]" daemon=no autostart=no connection=no tray client_signal autostart_mode
    keep_awake::init_paths || return 1
    autostart_mode="$(keep_awake::autostart_mode)"
    if status_json="$(keep_awake::daemon_status_json)"; then
        daemon=yes
        holders="$(printf '%s\n' "$status_json" \
            | sed -nE 's/.*"activeHolders":(\[[^]]*]).*/\1/p')"
        [ -n "$holders" ] || holders="[]"
    fi
    keep_awake::autostart_installed && autostart=yes
    keep_awake::host_connection_present && connection=yes
    if [ "$autostart_mode" = system ]; then
        tray="$(keep_awake::tray::status)"
    else
        tray="not installed (autostart: $autostart_mode)"
    fi
    client_signal="$(keep_awake::client_signal_status "$daemon")"
    printf 'Daemon reachable: %s\n' "$daemon"
    printf 'Holders: %s\n' "$holders"
    printf 'Autostart installed: %s\n' "$autostart"
    printf 'autostart: %s\n' "$autostart_mode"
    printf 'Host connection present: %s\n' "$connection"
    printf 'Client signal: %s\n' "$client_signal"
    printf 'Tray: %s\n' "$tray"
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
    disable)     keep_awake::disable ;;
    status)      keep_awake::status ;;
    teardown)    keep_awake::teardown "$@" ;;
    go-prereq)   keep_awake::go_prereq ;;
    go-remedy)   keep_awake::go_remedy; printf '\n' ;;
    -h|--help|'') usage ;;
    *) printf 'ensure-keep-awake.sh: unknown command %s\n' "$command_name" >&2; usage >&2; exit 2 ;;
esac
