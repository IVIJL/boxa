#!/usr/bin/env bash
set -euo pipefail

# Canonical lifecycle for the optional keep-awake host daemon. The CLI,
# provisioning registry, installer, and uninstaller all delegate here so the
# binary, platform autostart, and global Host connection converge together.

BOXA_DIR="${BOXA_DIR:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
KEEP_AWAKE_PORT="${BOXA_KEEP_AWAKE_PORT:-17777}"
KEEP_AWAKE_TASK_NAME="BoxaKeepAwake"
KEEP_AWAKE_LAUNCH_LABEL="dev.boxa.keep-awake"
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
KEEP_AWAKE_AUTOSTART_FILE=""
KEEP_AWAKE_BOXA="${BOXA_KEEP_AWAKE_BOXA_COMMAND:-$BOXA_DIR/docker-run.sh}"

usage() {
    cat <<'EOF'
Usage: ensure-keep-awake.sh <offer|probe|enable|disable|status|teardown|go-prereq|go-remedy> [options]

Canonical lifecycle helper for boxa's elective keep-awake daemon.

Options for offer:
  --yes              Enable without prompting.
  --non-interactive  Print the later-enable command without recording a choice.
  --interactive      Force the prompt (test seam).

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
            ;;
        macos)
            KEEP_AWAKE_INSTALL_DIR="${BOXA_KEEP_AWAKE_INSTALL_DIR:-$HOME/Library/Application Support/Boxa}"
            KEEP_AWAKE_BINARY="$KEEP_AWAKE_INSTALL_DIR/keep-awake"
            KEEP_AWAKE_AUTOSTART_FILE="$HOME/Library/LaunchAgents/${KEEP_AWAKE_LAUNCH_LABEL}.plist"
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
        KEEP_AWAKE_WINDOWS_BINARY="$(wslpath -w "$KEEP_AWAKE_BINARY")"
        KEEP_AWAKE_WINDOWS_LOG="$(wslpath -w "$KEEP_AWAKE_LOG_FILE")"
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
    KEEP_AWAKE_WINDOWS_BINARY="${windows_local_appdata}\\Boxa\\keep-awake.exe"
    KEEP_AWAKE_WINDOWS_LOG="${windows_local_appdata}\\Boxa\\keep-awake.log"
}

keep_awake::state_field() {
    local field="$1"
    [ -f "$KEEP_AWAKE_STATE_FILE" ] || return 1
    awk -F= -v key="$field" '$1 == key { print substr($0, index($0, "=") + 1); exit }' \
        "$KEEP_AWAKE_STATE_FILE"
}

keep_awake::write_state() {
    local enabled="$1" optout="$2" tmp
    mkdir -p "$KEEP_AWAKE_CONFIG_DIR" || return 1
    tmp="${KEEP_AWAKE_STATE_FILE}.tmp.$$"
    if ! printf 'enabled=%s\noptout=%s\n' "$enabled" "$optout" > "$tmp" \
        || ! chmod 0600 "$tmp" \
        || ! mv "$tmp" "$KEEP_AWAKE_STATE_FILE"; then
        rm -f "$tmp"
        return 1
    fi
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
            schtasks.exe /Query /TN "$KEEP_AWAKE_TASK_NAME" >/dev/null 2>&1
            ;;
    esac
}

keep_awake::probe() {
    keep_awake::init_paths || { printf 'missing\n'; return 0; }
    if [ "$(keep_awake::state_field optout 2>/dev/null || true)" = true ]; then
        printf 'declined\n'
    elif [ "$(keep_awake::state_field enabled 2>/dev/null || true)" = true ] \
        && [ -x "$KEEP_AWAKE_BINARY" ] \
        && keep_awake::autostart_installed \
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
            printf 'Run: brew install go'
            ;;
        linux|wsl2)
            manager=""
            for manager in apt-get dnf pacman zypper apk; do
                command -v "$manager" >/dev/null 2>&1 && break
                manager=""
            done
            case "$manager" in
                apt-get) printf 'Run: sudo apt-get install -y golang-go' ;;
                dnf)     printf 'Run: sudo dnf install -y golang' ;;
                pacman)  printf 'Run: sudo pacman -S go' ;;
                zypper)  printf 'Run: sudo zypper install -y go' ;;
                apk)     printf 'Run: sudo apk add go' ;;
                *)       printf 'Install Go from https://go.dev/doc/install' ;;
            esac
            ;;
        *)
            printf 'Install Go from https://go.dev/doc/install'
            ;;
    esac
}

keep_awake::go_prereq() {
    keep_awake::init_paths >/dev/null 2>&1 || return 1
    [ -x "$KEEP_AWAKE_BINARY" ] || command -v go >/dev/null 2>&1
}

keep_awake::check_enable_prereqs() {
    keep_awake::init_paths || return 1
    if [ ! -x "$KEEP_AWAKE_BINARY" ] && ! command -v go >/dev/null 2>&1; then
        printf 'keep-awake: Go toolchain not found. %s\n' "$(keep_awake::go_remedy)" >&2
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
            command -v systemctl >/dev/null 2>&1 || {
                printf 'keep-awake: systemctl is required for Linux user autostart.\n' >&2; return 1;
            }
            ;;
        macos)
            command -v launchctl >/dev/null 2>&1 || {
                printf 'keep-awake: launchctl is required for macOS user autostart.\n' >&2; return 1;
            }
            ;;
        wsl2)
            if ! command -v powershell.exe >/dev/null 2>&1 \
                || ! command -v schtasks.exe >/dev/null 2>&1 \
                || ! command -v wslpath >/dev/null 2>&1; then
                    printf 'keep-awake: WSL interop requires powershell.exe, schtasks.exe, and wslpath.\n' >&2
                    return 1
            fi
            ;;
    esac
}

keep_awake::build_binary() {
    local output="$1"
    if [ "$KEEP_AWAKE_PLATFORM" = wsl2 ]; then
        (cd "$BOXA_DIR/keep-awake" && GOOS=windows go build -trimpath -o "$output" .)
    else
        (cd "$BOXA_DIR/keep-awake" && go build -trimpath -o "$output" .)
    fi
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
            local action gateway
            gateway="$(ip route show default 2>/dev/null | awk 'NR == 1 { print $3; exit }')"
            action="\"$KEEP_AWAKE_WINDOWS_BINARY\" -port $KEEP_AWAKE_PORT -log-file \"$KEEP_AWAKE_WINDOWS_LOG\""
            [ -z "$gateway" ] || action="$action -listen-address $gateway"
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
    keep_awake::remove_autostart
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
    local tmp_dir="" built_binary=""
    keep_awake::check_enable_prereqs || return 1

    if [ ! -x "$KEEP_AWAKE_BINARY" ]; then
        tmp_dir="$(mktemp -d)"
        built_binary="$tmp_dir/$(basename "$KEEP_AWAKE_BINARY")"
        if ! keep_awake::build_binary "$built_binary"; then
            rm -rf "$tmp_dir"
            printf 'keep-awake: Go build failed; no host state was changed.\n' >&2
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

    if ! keep_awake::install_autostart; then
        keep_awake::rollback
        printf 'keep-awake: autostart installation failed; rolled back.\n' >&2
        return 1
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
    if ! keep_awake::write_state true false; then
        keep_awake::rollback
        printf 'keep-awake: could not record enabled state; rolled back.\n' >&2
        return 1
    fi
    printf 'Keep-awake enabled: daemon running, autostart installed, Host connection active on port %s.\n' \
        "$KEEP_AWAKE_PORT"
}

keep_awake::teardown() {
    local keep_connection=false remove_state=false arg rc=0
    for arg in "$@"; do
        case "$arg" in
            --keep-connection) keep_connection=true ;;
            --remove-state) remove_state=true ;;
            *) printf 'keep-awake teardown: unknown option %s\n' "$arg" >&2; return 2 ;;
        esac
    done
    keep_awake::init_paths || return 1
    if ! $keep_connection; then
        keep_awake::remove_host_connection || rc=1
    fi
    keep_awake::remove_autostart
    rm -f "$KEEP_AWAKE_BINARY" || rc=1
    if $remove_state; then
        rm -f "$KEEP_AWAKE_STATE_FILE" || rc=1
    else
        keep_awake::write_state false true || rc=1
    fi
    return "$rc"
}

keep_awake::disable() {
    keep_awake::teardown
    printf 'Keep-awake disabled: daemon stopped, autostart removed, Host connection removed.\n'
}

keep_awake::status() {
    local status_json="" holders="[]" daemon=no autostart=no connection=no
    keep_awake::init_paths || return 1
    if status_json="$(keep_awake::daemon_status_json)"; then
        daemon=yes
        holders="$(printf '%s\n' "$status_json" \
            | sed -nE 's/.*"activeHolders":(\[[^]]*]).*/\1/p')"
        [ -n "$holders" ] || holders="[]"
    fi
    keep_awake::autostart_installed && autostart=yes
    keep_awake::host_connection_present && connection=yes
    printf 'Daemon reachable: %s\n' "$daemon"
    printf 'Holders: %s\n' "$holders"
    printf 'Autostart installed: %s\n' "$autostart"
    printf 'Host connection present: %s\n' "$connection"
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
        keep_awake::enable
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
        y|Y|yes|YES) keep_awake::enable ;;
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
    enable)      keep_awake::enable ;;
    disable)     keep_awake::disable ;;
    status)      keep_awake::status ;;
    teardown)    keep_awake::teardown "$@" ;;
    go-prereq)   keep_awake::go_prereq ;;
    go-remedy)   keep_awake::go_remedy; printf '\n' ;;
    -h|--help|'') usage ;;
    *) printf 'ensure-keep-awake.sh: unknown command %s\n' "$command_name" >&2; usage >&2; exit 2 ;;
esac
