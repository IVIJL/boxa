#!/usr/bin/env bash
set -euo pipefail

BOXA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export BOXA_DIR
KEEP_AWAKE="$BOXA_DIR/scripts/ensure-keep-awake.sh"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

export HOME="$TMPROOT/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_STATE_HOME="$HOME/.local/state"
export BOXA_KEEP_AWAKE_PLATFORM=linux
export BOXA_KEEP_AWAKE_INSTALL_DIR="$TMPROOT/install"
export BOXA_KEEP_AWAKE_BOXA_COMMAND="$TMPROOT/bin/boxa"
export KEEP_AWAKE_TEST_LOG="$TMPROOT/calls.log"
export KEEP_AWAKE_TEST_TASK="$TMPROOT/task"
export KEEP_AWAKE_TEST_LAUNCHD="$TMPROOT/launchd"
export KEEP_AWAKE_TEST_SYSTEMD="$TMPROOT/systemd"
export KEEP_AWAKE_TEST_CONNECT="$XDG_CONFIG_HOME/boxa/connect/_all.tsv"
export KEEP_AWAKE_TEST_CURL_HEALTHY=true
export KEEP_AWAKE_TEST_CONNECT_FAIL=false
export KEEP_AWAKE_TEST_DOCKER_FAIL=false
mkdir -p "$HOME" "$TMPROOT/bin"
: > "$KEEP_AWAKE_TEST_LOG"

fail_count=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        printf 'PASS  %s\n' "$label"
    else
        printf 'FAIL  %s\n      expected: %q\n      actual:   %q\n' \
            "$label" "$expected" "$actual"
        fail_count=$((fail_count + 1))
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        printf 'PASS  %s\n' "$label"
    else
        printf 'FAIL  %s\n      missing: %q\n      actual:  %q\n' \
            "$label" "$needle" "$haystack"
        fail_count=$((fail_count + 1))
    fi
}

file_exists() {
    [ -e "$1" ] && printf true || printf false
}

cat > "$TMPROOT/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "$KEEP_AWAKE_TEST_LOG"
case " $* " in
    *' is-enabled '*) [ -f "$KEEP_AWAKE_TEST_SYSTEMD" ] ;;
    *' enable --now '*) : > "$KEEP_AWAKE_TEST_SYSTEMD" ;;
    *' disable --now '*) rm -f "$KEEP_AWAKE_TEST_SYSTEMD" ;;
esac
EOF

cat > "$TMPROOT/bin/launchctl" <<'EOF'
#!/usr/bin/env bash
printf 'launchctl %s\n' "$*" >> "$KEEP_AWAKE_TEST_LOG"
case "${1:-}" in
    print)     [ -f "$KEEP_AWAKE_TEST_LAUNCHD" ] ;;
    bootstrap) : > "$KEEP_AWAKE_TEST_LAUNCHD" ;;
    bootout)   rm -f "$KEEP_AWAKE_TEST_LAUNCHD" ;;
esac
EOF

cat > "$TMPROOT/bin/schtasks.exe" <<'EOF'
#!/usr/bin/env bash
printf 'schtasks %s\n' "$*" >> "$KEEP_AWAKE_TEST_LOG"
case "${1:-}" in
    /Query)  [ -f "$KEEP_AWAKE_TEST_TASK" ] ;;
    /Create) : > "$KEEP_AWAKE_TEST_TASK" ;;
    /Delete) rm -f "$KEEP_AWAKE_TEST_TASK" ;;
esac
EOF

cat > "$TMPROOT/bin/powershell.exe" <<'EOF'
#!/usr/bin/env bash
printf 'C:\Users\Test\AppData\Local\r\n'
EOF

cat > "$TMPROOT/bin/wslpath" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    -w) printf 'C:\\Boxa\\%s\n' "$(basename "$2")" ;;
    -u) printf '%s/windows-local-appdata\n' "${TMPROOT:?}" ;;
esac
EOF

cat > "$TMPROOT/bin/ip" <<'EOF'
#!/usr/bin/env bash
printf 'default via 172.30.96.1 dev eth0\n'
EOF

cat > "$TMPROOT/bin/curl" <<'EOF'
#!/usr/bin/env bash
[ "$KEEP_AWAKE_TEST_CURL_HEALTHY" = true ] || exit 7
printf '{"activeHolders":[{"agent":"codex","session":"test","remainingTTLSeconds":899}],"isInhibited":true,"version":"test"}\n'
EOF

cat > "$TMPROOT/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$TMPROOT/bin/boxa" <<'EOF'
#!/usr/bin/env bash
printf 'boxa %s\n' "$*" >> "$KEEP_AWAKE_TEST_LOG"
if [ "${1:-}" = connect ] && [ "${2:-}" = host ]; then
    [ "$KEEP_AWAKE_TEST_CONNECT_FAIL" = false ] || exit 1
    mkdir -p "$(dirname "$KEEP_AWAKE_TEST_CONNECT")"
    printf 'keep-awake\thost\t17777\t17777\n' > "$KEEP_AWAKE_TEST_CONNECT"
elif [ "${1:-}" = connect ] && [ "${2:-}" = rm ]; then
    rm -f "$KEEP_AWAKE_TEST_CONNECT"
fi
EOF

chmod +x "$TMPROOT/bin"/*
export TMPROOT
export PATH="$TMPROOT/bin:$PATH"

# The fresh-install offer records a decline once without needing Go.
decline_output="$(printf 'n\n' | "$KEEP_AWAKE" offer --interactive)"
assert_contains "offer reports later enable command" "boxa keep-awake enable" "$decline_output"
assert_eq "decline marker is remembered" "declined" "$("$KEEP_AWAKE" probe)"
second_offer="$("$KEEP_AWAKE" offer --interactive)"
assert_eq "decided offer does not prompt again" "" "$second_offer"

# With neither Docker nor Go available, enable prints the Docker-first remedy
# and mutates no binary, autostart, or Host connection state.
rm -f "$XDG_CONFIG_HOME/boxa/keep-awake.conf"
mkdir -p "$TMPROOT/bash-only"
ln -s "$(command -v bash)" "$TMPROOT/bash-only/bash"
missing_tools_output="$(PATH="$TMPROOT/bash-only" "$KEEP_AWAKE" enable 2>&1 || true)"
assert_contains "missing build tools recommend Docker first" \
    "Have Docker installed and running" "$missing_tools_output"
assert_contains "missing build tools mention local Go only as fallback" \
    "Local fallback: install Go from https://go.dev/doc/install" "$missing_tools_output"
assert_eq "missing build tools fail their prerequisite probe" fail \
    "$(PATH="$TMPROOT/bash-only" "$KEEP_AWAKE" go-prereq >/dev/null 2>&1 && printf pass || printf fail)"
assert_eq "missing build tools leave binary absent" false "$(file_exists "$TMPROOT/install/keep-awake")"
assert_eq "missing build tools leave autostart absent" false "$(file_exists "$KEEP_AWAKE_TEST_SYSTEMD")"
assert_eq "missing build tools leave Host connection absent" false "$(file_exists "$KEEP_AWAKE_TEST_CONNECT")"

cat > "$TMPROOT/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "$KEEP_AWAKE_TEST_LOG"
[ "$KEEP_AWAKE_TEST_DOCKER_FAIL" = false ] || exit 1
host_output_dir=""
container_output=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --volume)
            case "$2" in
                *:/out) host_output_dir="${2%:/out}" ;;
            esac
            shift 2
            ;;
        -o)
            container_output="$2"
            shift 2
            ;;
        *) shift ;;
    esac
done
[ -n "$host_output_dir" ] && [ -n "$container_output" ] || exit 2
output_name="${container_output#/out/}"
printf '#!/usr/bin/env bash\nexit 0\n' > "$host_output_dir/$output_name"
chmod +x "$host_output_dir/$output_name"
EOF
chmod +x "$TMPROOT/bin/docker"

assert_eq "Docker satisfies the build prerequisite probe" pass \
    "$("$KEEP_AWAKE" go-prereq >/dev/null 2>&1 && printf pass || printf fail)"

enable_output="$("$KEEP_AWAKE" enable)"
assert_contains "enable reports all converged components" \
    "daemon running, autostart installed, Host connection active" "$enable_output"
assert_eq "enable installs binary" true "$(file_exists "$TMPROOT/install/keep-awake")"
assert_eq "enable installs Linux autostart" true "$(file_exists "$KEEP_AWAKE_TEST_SYSTEMD")"
assert_eq "enable creates global Host connection" true "$(file_exists "$KEEP_AWAKE_TEST_CONNECT")"
assert_eq "enabled elective probes OK" ok "$("$KEEP_AWAKE" probe)"
docker_build_log="$(grep '^docker ' "$KEEP_AWAKE_TEST_LOG")"
assert_contains "default build uses the pinned golang image" "golang:1.22" "$docker_build_log"
assert_contains "Docker build mounts source read-only" \
    "$BOXA_DIR/keep-awake:/src:ro" "$docker_build_log"
assert_contains "Docker build runs as the invoking user" \
    "--user $(id -u):$(id -g)" "$docker_build_log"
assert_contains "Docker build disables CGO" "--env CGO_ENABLED=0" "$docker_build_log"
assert_contains "Docker build provides a writable Go build cache" \
    "--env GOCACHE=/tmp/gocache" "$docker_build_log"
assert_eq "Docker-built artifact is owned by the invoking user" "$(id -u)" \
    "$(stat -c %u "$TMPROOT/install/keep-awake")"

status_output="$("$KEEP_AWAKE" status)"
assert_contains "status reports reachable daemon" "Daemon reachable: yes" "$status_output"
assert_contains "status reports active holders" '"agent":"codex"' "$status_output"
assert_contains "status reports autostart" "Autostart installed: yes" "$status_output"
assert_contains "status reports Host connection" "Host connection present: yes" "$status_output"

disable_output="$("$KEEP_AWAKE" disable)"
assert_contains "disable reports all reversed components" \
    "daemon stopped, autostart removed, Host connection removed" "$disable_output"
assert_eq "disable removes binary" false "$(file_exists "$TMPROOT/install/keep-awake")"
assert_eq "disable removes Linux autostart" false "$(file_exists "$KEEP_AWAKE_TEST_SYSTEMD")"
assert_eq "disable removes Host connection" false "$(file_exists "$KEEP_AWAKE_TEST_CONNECT")"
assert_eq "disable records deliberate opt-out" declined "$("$KEEP_AWAKE" probe)"
export KEEP_AWAKE_TEST_CURL_HEALTHY=false
disabled_status="$("$KEEP_AWAKE" status)"
assert_contains "disabled status reports daemon down" "Daemon reachable: no" "$disabled_status"
assert_contains "disabled status reports autostart absent" "Autostart installed: no" "$disabled_status"
assert_contains "disabled status reports Host connection absent" "Host connection present: no" "$disabled_status"
export KEEP_AWAKE_TEST_CURL_HEALTHY=true

# A failed container build falls back to local Go, in that order.
cat > "$TMPROOT/bin/go" <<'EOF'
#!/usr/bin/env bash
printf 'go GOOS=%s CGO_ENABLED=%s %s\n' \
    "${GOOS:-native}" "${CGO_ENABLED:-unset}" "$*" >> "$KEEP_AWAKE_TEST_LOG"
output=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = -o ]; then output="$2"; shift 2; else shift; fi
done
[ -n "$output" ] || exit 2
printf '#!/usr/bin/env bash\nexit 0\n' > "$output"
chmod +x "$output"
EOF
chmod +x "$TMPROOT/bin/go"
rm -f "$XDG_CONFIG_HOME/boxa/keep-awake.conf"
: > "$KEEP_AWAKE_TEST_LOG"
export KEEP_AWAKE_TEST_DOCKER_FAIL=true
fallback_output="$("$KEEP_AWAKE" enable 2>&1)"
assert_contains "failed Docker build announces local fallback" \
    "Docker build failed; falling back to the local Go toolchain" "$fallback_output"
build_call_order="$(sed -n '/^docker /p; /^go /p' "$KEEP_AWAKE_TEST_LOG")"
assert_eq "Docker is attempted before local Go" $'docker\ngo' \
    "$(printf '%s\n' "$build_call_order" | sed 's/ .*//')"
assert_contains "local fallback also disables CGO" "CGO_ENABLED=0" "$build_call_order"
"$KEEP_AWAKE" disable >/dev/null
export KEEP_AWAKE_TEST_DOCKER_FAIL=false

# A post-start Host connection failure rolls back every newly-created part.
rm -f "$XDG_CONFIG_HOME/boxa/keep-awake.conf"
export KEEP_AWAKE_TEST_CONNECT_FAIL=true
rollback_output="$("$KEEP_AWAKE" enable 2>&1 || true)"
assert_contains "Host connection failure reports rollback" "Host connection setup failed; rolled back" "$rollback_output"
assert_eq "rollback removes binary" false "$(file_exists "$TMPROOT/install/keep-awake")"
assert_eq "rollback removes autostart" false "$(file_exists "$KEEP_AWAKE_TEST_SYSTEMD")"
assert_eq "rollback removes Host connection" false "$(file_exists "$KEEP_AWAKE_TEST_CONNECT")"
export KEEP_AWAKE_TEST_CONNECT_FAIL=false

# Uninstall teardown stops daemon/autostart and removes its marker while
# deliberately leaving the Host connection to docker-run.sh's existing sweep.
"$KEEP_AWAKE" enable >/dev/null
"$KEEP_AWAKE" teardown --keep-connection --remove-state
assert_eq "uninstall teardown removes binary" false "$(file_exists "$TMPROOT/install/keep-awake")"
assert_eq "uninstall teardown removes autostart" false "$(file_exists "$KEEP_AWAKE_TEST_SYSTEMD")"
assert_eq "uninstall teardown leaves connection for sweep" true "$(file_exists "$KEEP_AWAKE_TEST_CONNECT")"
assert_eq "uninstall teardown removes elective marker" false \
    "$(file_exists "$XDG_CONFIG_HOME/boxa/keep-awake.conf")"
rm -f "$KEEP_AWAKE_TEST_CONNECT"

# macOS and Windows autostart branches are exercised with their native command
# surfaces while the daemon/build remain mocked.
export BOXA_KEEP_AWAKE_PLATFORM=macos
export BOXA_KEEP_AWAKE_INSTALL_DIR="$TMPROOT/macos-install"
"$KEEP_AWAKE" enable >/dev/null
assert_eq "macOS enable bootstraps launchd user agent" true "$(file_exists "$KEEP_AWAKE_TEST_LAUNCHD")"
assert_contains "macOS launchd command is user-scoped" "launchctl bootstrap gui/" "$(cat "$KEEP_AWAKE_TEST_LOG")"
"$KEEP_AWAKE" disable >/dev/null
assert_eq "macOS disable removes launchd user agent" false "$(file_exists "$KEEP_AWAKE_TEST_LAUNCHD")"

rm -f "$XDG_CONFIG_HOME/boxa/keep-awake.conf"
export BOXA_KEEP_AWAKE_PLATFORM=wsl2
export BOXA_KEEP_AWAKE_INSTALL_DIR="$TMPROOT/windows-install"
"$KEEP_AWAKE" enable >/dev/null
assert_eq "Windows enable creates scheduled task" true "$(file_exists "$KEEP_AWAKE_TEST_TASK")"
assert_contains "Windows task is scheduled at logon" "/SC ONLOGON" "$(cat "$KEEP_AWAKE_TEST_LOG")"
windows_wrapper="$TMPROOT/windows-install/start-keep-awake.ps1"
assert_eq "Windows task installs runtime gateway wrapper" true "$(file_exists "$windows_wrapper")"
assert_contains "Windows wrapper resolves vEthernet address at each start" \
    "Get-NetIPAddress -AddressFamily IPv4" "$(cat "$windows_wrapper")"
assert_contains "Windows wrapper retries while vEthernet is unavailable" \
    "Start-Sleep -Seconds 2" "$(cat "$windows_wrapper")"
assert_contains "Windows wrapper opts into the resolved non-loopback bind" \
    "'-listen-address', \$gateway, '-listen-unsafe'" "$(cat "$windows_wrapper")"
assert_contains "Windows wrapper logs loopback-only fallback" \
    "starting with loopback-only binding" "$(cat "$windows_wrapper")"
assert_contains "Windows wrapper keeps polling after loopback fallback" \
    "Start-Sleep -Seconds 30" "$(cat "$windows_wrapper")"
assert_contains "Windows wrapper tracks and stops its own fallback daemon" \
    "Stop-Process -Id \$daemon.Id" "$(cat "$windows_wrapper")"
assert_contains "Windows wrapper logs late adapter discovery" \
    "WSL vEthernet adapter appeared" "$(cat "$windows_wrapper")"
assert_contains "Windows wrapper logs dual-listener restart" \
    "restarting with loopback and vEthernet listeners" "$(cat "$windows_wrapper")"
assert_eq "Windows task does not bake in the current WSL gateway" "0" \
    "$(grep -c '172\.30\.96\.1' "$KEEP_AWAKE_TEST_LOG" || true)"
assert_contains "Windows Docker build targets Windows" \
    "--env GOOS=windows" "$(cat "$KEEP_AWAKE_TEST_LOG")"
rm -f "$windows_wrapper"
broken_windows_status="$("$KEEP_AWAKE" status 2>&1)"
assert_contains "Windows status rejects task with missing wrapper" \
    "Autostart installed: no" "$broken_windows_status"
assert_contains "Windows status gives wrapper repair hint" \
    "Repair with: boxa keep-awake enable" "$broken_windows_status"
assert_eq "Windows doctor probe rejects task with missing wrapper" missing \
    "$("$KEEP_AWAKE" probe 2>/dev/null)"
"$KEEP_AWAKE" enable >/dev/null
"$KEEP_AWAKE" disable >/dev/null
assert_eq "Windows disable deletes scheduled task" false "$(file_exists "$KEEP_AWAKE_TEST_TASK")"
assert_eq "Windows disable removes runtime gateway wrapper" false "$(file_exists "$windows_wrapper")"

# Public CLI routes the three subcommands to the canonical helper and exposes
# dedicated help without requiring Docker.
export BOXA_KEEP_AWAKE_PLATFORM=linux
export BOXA_KEEP_AWAKE_INSTALL_DIR="$TMPROOT/cli-install"
cli_help="$(bash "$BOXA_DIR/docker-run.sh" keep-awake --help)"
assert_contains "CLI help documents enable/disable/status" \
    "Usage: boxa keep-awake <enable|disable|status>" "$cli_help"
assert_contains "CLI help documents the Docker-first build" \
    "pinned golang Docker container" "$cli_help"
cli_status="$(bash "$BOXA_DIR/docker-run.sh" keep-awake status)"
assert_contains "CLI status reaches canonical helper" "Daemon reachable: yes" "$cli_status"

if [ "$fail_count" -gt 0 ]; then
    printf '\n%d test(s) failed.\n' "$fail_count"
    exit 1
fi

printf '\nAll keep-awake tests passed.\n'
