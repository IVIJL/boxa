#!/usr/bin/env bash
set -euo pipefail

BOXA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
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

# A clean missing-Go failure prints the exact platform command and mutates no
# binary, autostart, or Host connection state.
rm -f "$XDG_CONFIG_HOME/boxa/keep-awake.conf"
missing_go_output="$("$KEEP_AWAKE" enable 2>&1 || true)"
assert_contains "missing Go prints exact Debian command" \
    "Run: sudo apt-get install -y golang-go" "$missing_go_output"
assert_eq "missing Go leaves binary absent" false "$(file_exists "$TMPROOT/install/keep-awake")"
assert_eq "missing Go leaves autostart absent" false "$(file_exists "$KEEP_AWAKE_TEST_SYSTEMD")"
assert_eq "missing Go leaves Host connection absent" false "$(file_exists "$KEEP_AWAKE_TEST_CONNECT")"

cat > "$TMPROOT/bin/go" <<'EOF'
#!/usr/bin/env bash
printf 'go GOOS=%s %s\n' "${GOOS:-native}" "$*" >> "$KEEP_AWAKE_TEST_LOG"
output=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = -o ]; then output="$2"; shift 2; else shift; fi
done
[ -n "$output" ] || exit 2
printf '#!/usr/bin/env bash\nexit 0\n' > "$output"
chmod +x "$output"
EOF
chmod +x "$TMPROOT/bin/go"

enable_output="$("$KEEP_AWAKE" enable)"
assert_contains "enable reports all converged components" \
    "daemon running, autostart installed, Host connection active" "$enable_output"
assert_eq "enable installs binary" true "$(file_exists "$TMPROOT/install/keep-awake")"
assert_eq "enable installs Linux autostart" true "$(file_exists "$KEEP_AWAKE_TEST_SYSTEMD")"
assert_eq "enable creates global Host connection" true "$(file_exists "$KEEP_AWAKE_TEST_CONNECT")"
assert_eq "enabled elective probes OK" ok "$("$KEEP_AWAKE" probe)"

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
assert_contains "Windows build targets Windows" "go GOOS=windows" "$(cat "$KEEP_AWAKE_TEST_LOG")"
"$KEEP_AWAKE" disable >/dev/null
assert_eq "Windows disable deletes scheduled task" false "$(file_exists "$KEEP_AWAKE_TEST_TASK")"

# Public CLI routes the three subcommands to the canonical helper and exposes
# dedicated help without requiring Docker.
export BOXA_KEEP_AWAKE_PLATFORM=linux
export BOXA_KEEP_AWAKE_INSTALL_DIR="$TMPROOT/cli-install"
cli_help="$(bash "$BOXA_DIR/docker-run.sh" keep-awake --help)"
assert_contains "CLI help documents enable/disable/status" \
    "Usage: boxa keep-awake <enable|disable|status>" "$cli_help"
cli_status="$(bash "$BOXA_DIR/docker-run.sh" keep-awake status)"
assert_contains "CLI status reaches canonical helper" "Daemon reachable: yes" "$cli_status"

if [ "$fail_count" -gt 0 ]; then
    printf '\n%d test(s) failed.\n' "$fail_count"
    exit 1
fi

printf '\nAll keep-awake tests passed.\n'
