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
export KEEP_AWAKE_TEST_TRAY_TASK="$TMPROOT/tray-task"
export KEEP_AWAKE_TEST_LAUNCHD="$TMPROOT/launchd"
export KEEP_AWAKE_TEST_TRAY_LAUNCHD="$TMPROOT/tray-launchd"
export KEEP_AWAKE_TEST_SYSTEMD="$TMPROOT/systemd"
export KEEP_AWAKE_TEST_TRAY_SYSTEMD="$TMPROOT/tray-systemd"
export KEEP_AWAKE_TEST_CONNECT="$XDG_CONFIG_HOME/boxa/connect/_all.tsv"
export KEEP_AWAKE_TEST_TRAY_PROCESS=false
export KEEP_AWAKE_TEST_DAEMON_PROCESS=false
export KEEP_AWAKE_TEST_FIREWALL_ELEVATION=success
export KEEP_AWAKE_TEST_FIREWALL_RULE="$TMPROOT/firewall-rule"
export KEEP_AWAKE_TEST_CURL_HEALTHY=true
export KEEP_AWAKE_TEST_LOOPBACK_HEALTHY=true
export KEEP_AWAKE_TEST_GATEWAY_HEALTHY=true
export KEEP_AWAKE_TEST_CONNECT_FAIL=false
export KEEP_AWAKE_TEST_DOCKER_FAIL=false
export KEEP_AWAKE_TEST_TRAY_START_FAIL=false
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

assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        printf 'PASS  %s\n' "$label"
    else
        printf 'FAIL  %s\n      unexpected: %q\n      actual:     %q\n' \
            "$label" "$needle" "$haystack"
        fail_count=$((fail_count + 1))
    fi
}

assert_file_exists() {
    local label="$1" path="$2"
    if [ -e "$path" ]; then
        printf 'PASS  %s\n' "$label"
    else
        printf 'FAIL  %s\n      missing file: %s\n' "$label" "$path"
        fail_count=$((fail_count + 1))
    fi
}

mkdir -p "$TMPROOT/bash-only"
ln -s "$(command -v bash)" "$TMPROOT/bash-only/bash"

# Source the Linux tray functions without starting yad, then exercise both the
# optional jq path and the dependency-free fallback with valid hostile names.
linux_tray="$BOXA_DIR/keep-awake/tray/keep-awake-tray.sh"
hostile_status='{"activeHolders":[{"agent":"co]d\"ex\\path","session":"s]e\"ss\\ion","remainingTTLSeconds":42},{"agent":"plain","remainingTTLSeconds":7}],"isInhibited":true}'
jq_holders="$(bash -c 'source "$1" 17777 "$2"; keep_awake_tray::holders "$3"' \
    _ "$linux_tray" "$TMPROOT" "$hostile_status")"
assert_eq "Linux tray decodes hostile holder names with jq" \
    'co]d"ex\path/s]e"ss\ion (42s), plain (7s)' "$jq_holders"
fallback_holders="$(PATH="$TMPROOT/bash-only" bash -c \
    'source "$1" 17777 "$2"; keep_awake_tray::holders "$3"' \
    _ "$linux_tray" "$TMPROOT" "$hostile_status")"
assert_eq "Linux tray hides hostile holder names without jq" \
    "holder details unavailable" "$fallback_holders"

file_exists() {
    [ -e "$1" ] && printf true || printf false
}

cat > "$TMPROOT/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "$KEEP_AWAKE_TEST_LOG"
if [[ "$*" == *boxa-keep-awake-tray.service* ]]; then
    marker="$KEEP_AWAKE_TEST_TRAY_SYSTEMD"
else
    marker="$KEEP_AWAKE_TEST_SYSTEMD"
fi
case " $* " in
    *' is-enabled '*|*' is-active '*) [ -f "$marker" ] ;;
    *' enable --now '*)
        if [ "$marker" = "$KEEP_AWAKE_TEST_TRAY_SYSTEMD" ] \
            && [ "$KEEP_AWAKE_TEST_TRAY_START_FAIL" = true ]; then
            exit 1
        fi
        : > "$marker"
        ;;
    *' disable --now '*) rm -f "$marker" ;;
esac
EOF

cat > "$TMPROOT/bin/launchctl" <<'EOF'
#!/usr/bin/env bash
printf 'launchctl %s\n' "$*" >> "$KEEP_AWAKE_TEST_LOG"
if [[ "$*" == *keep-awake-tray* ]]; then
    marker="$KEEP_AWAKE_TEST_TRAY_LAUNCHD"
else
    marker="$KEEP_AWAKE_TEST_LAUNCHD"
fi
case "${1:-}" in
    print)
        [ -f "$marker" ] || exit 1
        printf 'state = running\n'
        ;;
    bootstrap)
        if [ "$marker" = "$KEEP_AWAKE_TEST_TRAY_LAUNCHD" ] \
            && [ "$KEEP_AWAKE_TEST_TRAY_START_FAIL" = true ]; then
            exit 1
        fi
        : > "$marker"
        ;;
    bootout)   rm -f "$marker" ;;
esac
EOF

cat > "$TMPROOT/bin/schtasks.exe" <<'EOF'
#!/usr/bin/env bash
printf 'schtasks %s\n' "$*" >> "$KEEP_AWAKE_TEST_LOG"
if [[ "$*" == *BoxaKeepAwakeTray* ]]; then
    marker="$KEEP_AWAKE_TEST_TRAY_TASK"
else
    marker="$KEEP_AWAKE_TEST_TASK"
fi
case "${1:-}" in
    /Query)  [ -f "$marker" ] ;;
    /Create)
        if [ "$marker" = "$KEEP_AWAKE_TEST_TRAY_TASK" ] \
            && [ "$KEEP_AWAKE_TEST_TRAY_START_FAIL" = true ]; then
            exit 1
        fi
        : > "$marker"
        ;;
    /Delete) rm -f "$marker" ;;
esac
EOF

cat > "$TMPROOT/bin/powershell.exe" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *Get-NetFirewallRule* ]]; then
    [ -f "$KEEP_AWAKE_TEST_FIREWALL_RULE" ]
    exit
fi
if [ "${1:-}" = -NoProfile ] && [ "${2:-}" = -EncodedCommand ]; then
    outer="$(printf '%s' "${3:-}" | base64 -d | iconv -f UTF-16LE)"
    inner_encoded="$(printf '%s' "$outer" \
        | sed -n "s/.*'-EncodedCommand','\([^']*\)'.*/\1/p")"
    inner="$(printf '%s' "$inner_encoded" | base64 -d | iconv -f UTF-16LE)"
    printf 'firewall %s\n' "$inner" >> "$KEEP_AWAKE_TEST_LOG"
    case "$KEEP_AWAKE_TEST_FIREWALL_ELEVATION" in
        decline) exit 3 ;;
        fail)    exit 1 ;;
    esac
    if [[ "$inner" == *New-NetFirewallRule* ]]; then
        : > "$KEEP_AWAKE_TEST_FIREWALL_RULE"
    elif [[ "$inner" == *Remove-NetFirewallRule* ]]; then
        rm -f "$KEEP_AWAKE_TEST_FIREWALL_RULE"
    fi
    exit 0
fi
if [[ "$*" == *"Name='keep-awake.exe'"* ]]; then
    [ "$KEEP_AWAKE_TEST_DAEMON_PROCESS" = true ]
    exit
fi
if [[ "$*" == *Get-ScheduledTask* ]]; then
    [ -f "$KEEP_AWAKE_TEST_TRAY_TASK" ]
    exit
fi
if [[ "$*" == *Get-CimInstance* && "$*" == *Stop-Process* ]]; then
    printf 'powershell %s\n' "$*" >> "$KEEP_AWAKE_TEST_LOG"
    exit 0
fi
if [[ "$*" == *Get-CimInstance* ]]; then
    [ "$KEEP_AWAKE_TEST_TRAY_PROCESS" = true ]
    exit
fi
if [[ "$*" == *Start-Process* && "$*" == *keep-awake-tray* ]]; then
    printf 'powershell %s\n' "$*" >> "$KEEP_AWAKE_TEST_LOG"
    exit 0
fi
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
printf 'default via %s dev eth0\n' "${KEEP_AWAKE_TEST_GATEWAY:-172.30.96.1}"
EOF

cat > "$TMPROOT/bin/curl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *'/v1/busy/'*|*'/v1/idle/'*)
        printf 'curl %s\n' "$*" >> "$KEEP_AWAKE_TEST_LOG"
        case "${*: -1}" in
            http://127.0.0.1:*) [ "$KEEP_AWAKE_TEST_LOOPBACK_HEALTHY" = true ] || exit 7 ;;
            *)                  [ "$KEEP_AWAKE_TEST_GATEWAY_HEALTHY" = true ] || exit 7 ;;
        esac
        ;;
    *'/v1/status')
        printf 'status %s\n' "${*: -1}" >> "$KEEP_AWAKE_TEST_LOG"
        case "${*: -1}" in
            http://127.0.0.1:*) [ "$KEEP_AWAKE_TEST_LOOPBACK_HEALTHY" = true ] || exit 7 ;;
            *)                  [ "$KEEP_AWAKE_TEST_GATEWAY_HEALTHY" = true ] || exit 7 ;;
        esac
        ;;
esac
[ "$KEEP_AWAKE_TEST_CURL_HEALTHY" = true ] || exit 7
printf '{"activeHolders":[{"agent":"codex","session":"test","remainingTTLSeconds":899}],"isInhibited":true,"version":"test"}\n'
EOF

cat > "$TMPROOT/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$TMPROOT/bin/yad" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$TMPROOT/bin/swiftc" <<'EOF'
#!/usr/bin/env bash
output=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = -o ]; then output="$2"; shift 2; else shift; fi
done
[ -n "$output" ] || exit 2
printf '#!/usr/bin/env bash\nexit 0\n' > "$output"
chmod +x "$output"
EOF

cat > "$TMPROOT/bin/boxa" <<'EOF'
#!/usr/bin/env bash
printf 'boxa %s\n' "$*" >> "$KEEP_AWAKE_TEST_LOG"
if [ "${1:-}" = connect ] && [ "${2:-}" = host ]; then
    # Mirrors docker-run.sh: the global record persists before the per-box
    # loop, so a partial failure still leaves the record behind.
    mkdir -p "$(dirname "$KEEP_AWAKE_TEST_CONNECT")"
    printf 'keep-awake\thost\t17777\t17777\n' > "$KEEP_AWAKE_TEST_CONNECT"
    [ "$KEEP_AWAKE_TEST_CONNECT_FAIL" = false ] || exit 1
elif [ "${1:-}" = connect ] && [ "${2:-}" = rm ]; then
    rm -f "$KEEP_AWAKE_TEST_CONNECT"
fi
EOF

chmod +x "$TMPROOT/bin"/*
export TMPROOT
export PATH="$TMPROOT/bin:$PATH"

# The managed client hook uses the Host connection API, is project-scoped,
# bounds curl to one second, and silently succeeds when the daemon is absent.
agent_awake="$BOXA_DIR/config/claude/hooks/agent-awake.sh"
: > "$KEEP_AWAKE_TEST_LOG"
BOXA_PROJECT_NAME=sample-project "$agent_awake" busy
assert_contains "busy hook calls versioned Host connection endpoint" \
    "http://127.0.0.1:17777/v1/busy/claude?ttl=900&session=sample-project" \
    "$(cat "$KEEP_AWAKE_TEST_LOG")"
assert_contains "busy hook caps curl at one second" \
    "-m 1" "$(cat "$KEEP_AWAKE_TEST_LOG")"
assert_eq "reachable loopback stops before the gateway" 1 \
    "$(grep -c '/v1/busy/' "$KEEP_AWAKE_TEST_LOG")"

# On a WSL2 NAT host the daemon is a Windows process behind the default
# gateway; a loopback-only hook would signal nothing at all there. The platform
# fixtures keep these cases decidable on any machine.
hook_fixtures="$TMPROOT/hook-platform"
mkdir -p "$hook_fixtures"
: > "$hook_fixtures/WSLInterop"
printf 'Linux version 6.8.0-generic (gcc 13)\n' > "$hook_fixtures/version-linux"
printf '{"project":"sample"}\n' > "$hook_fixtures/identity.json"
export BOXA_WSL_INTEROP_FILE="$hook_fixtures/WSLInterop"
export BOXA_PROC_VERSION_FILE="$hook_fixtures/version-linux"
export BOXA_CONTAINER_IDENTITY_FILE="$hook_fixtures/absent-identity.json"

: > "$KEEP_AWAKE_TEST_LOG"
export KEEP_AWAKE_TEST_LOOPBACK_HEALTHY=false
BOXA_PROJECT_NAME=sample-project "$agent_awake" busy
assert_contains "unreachable loopback falls back to the gateway on a WSL2 host" \
    "http://172.30.96.1:17777/v1/busy/claude?ttl=900&session=sample-project" \
    "$(cat "$KEEP_AWAKE_TEST_LOG")"

# Off a WSL2 host the default gateway is an unrelated machine: signalling it
# would leak the project name and stall every Claude event on a timeout.
: > "$KEEP_AWAKE_TEST_LOG"
BOXA_WSL_INTEROP_FILE="$hook_fixtures/absent-interop" \
    BOXA_PROJECT_NAME=sample-project "$agent_awake" busy
assert_eq "native Linux never signals the default gateway" 0 \
    "$(grep -c '172.30.96.1' "$KEEP_AWAKE_TEST_LOG")"

# A custom-kernel WSL2 host has no interop binfmt entry but still needs the
# Windows gateway, so /proc/version remains a valid fallback signal.
: > "$KEEP_AWAKE_TEST_LOG"
printf 'Linux version 6.6.0-custom (Microsoft@WSL2)\n' \
    > "$hook_fixtures/version-wsl"
BOXA_WSL_INTEROP_FILE="$hook_fixtures/absent-interop" \
    BOXA_PROC_VERSION_FILE="$hook_fixtures/version-wsl" \
    BOXA_PROJECT_NAME=sample-project "$agent_awake" busy
assert_contains "custom-kernel WSL2 still reaches the gateway" \
    "http://172.30.96.1:17777/v1/busy/claude" \
    "$(cat "$KEEP_AWAKE_TEST_LOG")"
: > "$KEEP_AWAKE_TEST_LOG"
BOXA_CONTAINER_IDENTITY_FILE="$hook_fixtures/identity.json" \
    BOXA_PROJECT_NAME=sample-project "$agent_awake" busy
assert_eq "a Container never signals its bridge gateway" 0 \
    "$(grep -c '172.30.96.1' "$KEEP_AWAKE_TEST_LOG")"
export KEEP_AWAKE_TEST_LOOPBACK_HEALTHY=true
: > "$KEEP_AWAKE_TEST_LOG"
# A failing ps keeps the idle path deterministic: with a real ps the hook
# sees whatever shell-snapshot children the invoking agent session has live.
env -u BOXA_PROJECT_NAME BOXA_PS_COMMAND=false "$agent_awake" idle
assert_contains "idle hook uses the default session" \
    "http://127.0.0.1:17777/v1/idle/claude?session=default" \
    "$(cat "$KEEP_AWAKE_TEST_LOG")"
export KEEP_AWAKE_TEST_CURL_HEALTHY=false
hook_down_output="$($agent_awake busy 2>&1)"
assert_eq "unreachable daemon leaves hook silent" "" "$hook_down_output"
assert_eq "unreachable daemon leaves hook successful" pass \
    "$($agent_awake busy >/dev/null 2>&1 && printf pass || printf fail)"
export KEEP_AWAKE_TEST_CURL_HEALTHY=true

# Stop keeps the lease while a shell-snapshot child of the owning Claude is
# alive. The ps stub substitutes the hook PID into otherwise static trees, so
# no real background process is involved in these checks.
cat > "$TMPROOT/bin/agent-awake-ps" <<'EOF'
#!/usr/bin/env bash
hook_pid="${BOXA_AGENT_AWAKE_HOOK_PID:?}"
case "${KEEP_AWAKE_TEST_PROCESS_TREE:-absent}" in
    background)
        printf '%s\n' \
            '100 1 claude /usr/bin/claude' \
            "$hook_pid 100 agent-awake.sh agent-awake.sh idle" \
            '200 100 zsh zsh -c source ~/.claude/shell-snapshots/snapshot-zsh-bg.sh'
        ;;
    absent)
        printf '%s\n' \
            '100 1 claude /usr/bin/claude' \
            "$hook_pid 100 agent-awake.sh agent-awake.sh idle"
        ;;
    self)
        printf '%s\n' \
            '100 1 claude /usr/bin/claude' \
            '300 100 zsh zsh -c source ~/.claude/shell-snapshots/snapshot-zsh-hook.sh' \
            "$hook_pid 300 agent-awake.sh agent-awake.sh idle"
        ;;
    failure)
        exit 1
        ;;
esac
EOF
chmod +x "$TMPROOT/bin/agent-awake-ps"
export BOXA_PS_COMMAND="$TMPROOT/bin/agent-awake-ps"

: > "$KEEP_AWAKE_TEST_LOG"
env -u BOXA_PROJECT_NAME KEEP_AWAKE_TEST_PROCESS_TREE=background "$agent_awake" idle
assert_contains "Stop stays busy while a background shell-snapshot child runs" \
    "/v1/busy/claude?ttl=900&session=default" \
    "$(cat "$KEEP_AWAKE_TEST_LOG")"

: > "$KEEP_AWAKE_TEST_LOG"
env -u BOXA_PROJECT_NAME KEEP_AWAKE_TEST_PROCESS_TREE=absent "$agent_awake" idle
assert_contains "Stop becomes idle without background shell-snapshot children" \
    "/v1/idle/claude?session=default" "$(cat "$KEEP_AWAKE_TEST_LOG")"

: > "$KEEP_AWAKE_TEST_LOG"
env -u BOXA_PROJECT_NAME KEEP_AWAKE_TEST_PROCESS_TREE=self "$agent_awake" idle
assert_contains "Stop excludes its own shell-snapshot process chain" \
    "/v1/idle/claude?session=default" "$(cat "$KEEP_AWAKE_TEST_LOG")"

: > "$KEEP_AWAKE_TEST_LOG"
env -u BOXA_PROJECT_NAME KEEP_AWAKE_TEST_PROCESS_TREE=failure "$agent_awake" idle
assert_contains "Stop falls back to idle when process detection fails" \
    "/v1/idle/claude?session=default" "$(cat "$KEEP_AWAKE_TEST_LOG")"
unset BOXA_PS_COMMAND

# Existing shared settings are merged rather than replaced. Calling the
# migration twice must leave one exact entry per event and preserve custom data.
claude_defaults="$BOXA_DIR/config/claude"
claude_target="$TMPROOT/claude-target"
mkdir -p "$claude_target/hooks"
cat > "$claude_target/settings.json" <<'EOF'
{
  "customUserSetting": true,
  "hooks": {
    "Stop": [{"hooks": [{"type": "command", "command": "/custom/stop.sh"}]}],
    "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "/custom/prompt.sh"}]}]
  }
}
EOF
for _ in 1 2; do
    BOXA_CLAUDE_DEFAULTS="$claude_defaults" BOXA_CLAUDE_TARGET="$claude_target" \
        bash -c 'source "$1"; migrate_agent_awake_hooks' \
        _ "$BOXA_DIR/scripts/setup-claude.sh"
done
assert_file_exists "settings migration installs missing managed hook" \
    "$claude_target/hooks/agent-awake.sh"
assert_eq "settings migration preserves custom settings" true \
    "$(jq -r '.customUserSetting' "$claude_target/settings.json")"
assert_eq "settings migration preserves custom hooks" 2 \
    "$(jq '[.hooks[][]?.hooks[]? | select(.command | startswith("/custom/"))] | length' \
        "$claude_target/settings.json")"
assert_eq "settings migration adds one prompt heartbeat" 1 \
    "$(jq '[.hooks.UserPromptSubmit[] | select(.hooks == [{"type":"command","command":"~/.claude/hooks/agent-awake.sh busy"}])] | length' \
        "$claude_target/settings.json")"
assert_eq "settings migration adds one pre-tool heartbeat" 1 \
    "$(jq '[.hooks.PreToolUse[] | select(.hooks == [{"type":"command","command":"~/.claude/hooks/agent-awake.sh busy"}])] | length' \
        "$claude_target/settings.json")"
assert_eq "settings migration adds one stop release" 1 \
    "$(jq '[.hooks.Stop[] | select(.hooks == [{"type":"command","command":"~/.claude/hooks/agent-awake.sh idle"}])] | length' \
        "$claude_target/settings.json")"

# An already-seeded hook from an older boxa must be refreshed, or a fixed
# signal path never reaches users who installed before the fix.
run_agent_awake_migration() {
    BOXA_CLAUDE_DEFAULTS="$claude_defaults" BOXA_CLAUDE_TARGET="$claude_target" \
        bash -c 'source "$1"; migrate_agent_awake_hooks' \
        _ "$BOXA_DIR/scripts/setup-claude.sh"
}
# Byte-for-byte the hook boxa shipped before the ownership marker existed: the
# loopback-only signal path that stopped reaching the daemon on WSL2 NAT hosts.
cat > "$claude_target/hooks/agent-awake.sh" <<'LEGACY_HOOK'
#!/bin/sh
# Signal boxa's host keep-awake daemon; silently no-op when it is unavailable.

action="${1:-busy}"
session="${BOXA_PROJECT_NAME:-default}"

case "$action" in
    idle)
        url="http://127.0.0.1:17777/v1/idle/claude?session=$session"
        ;;
    *)
        url="http://127.0.0.1:17777/v1/busy/claude?ttl=900&session=$session"
        ;;
esac

curl -fsS -m 1 "$url" >/dev/null 2>&1 || true
exit 0
LEGACY_HOOK
run_agent_awake_migration
assert_eq "settings migration refreshes the shipped legacy hook" same \
    "$(cmp -s "$claude_defaults/hooks/agent-awake.sh" \
        "$claude_target/hooks/agent-awake.sh" && printf same || printf stale)"
# A user's own edit of that legacy hook keeps its descriptive header but is no
# longer byte-identical, so boxa must not claim ownership of it.
printf '#!/bin/sh\n# Signal boxa%s host keep-awake daemon; with my own tweak.\nexit 0\n' \
    "'s" > "$claude_target/hooks/agent-awake.sh"
run_agent_awake_migration
assert_contains "settings migration leaves a customized legacy hook alone" \
    "my own tweak" "$(cat "$claude_target/hooks/agent-awake.sh")"
printf '#!/bin/sh\n# my own signal hook\nexit 0\n' \
    > "$claude_target/hooks/agent-awake.sh"
run_agent_awake_migration
assert_contains "settings migration leaves a user-owned hook alone" \
    "my own signal hook" "$(cat "$claude_target/hooks/agent-awake.sh")"

# A symlinked hook points at a file boxa does not manage — typically the user's
# dotfiles repo. Writing through the link would silently edit that file.
linked_hook_source="$claude_target/dotfiles-agent-awake.sh"
cp "$claude_defaults/hooks/agent-awake.sh" "$linked_hook_source"
printf '# my dotfiles copy\n' >> "$linked_hook_source"
ln -sf "$linked_hook_source" "$claude_target/hooks/agent-awake.sh"
run_agent_awake_migration
assert_contains "settings migration never writes through a symlinked hook" \
    "my dotfiles copy" "$(cat "$linked_hook_source")"
assert_eq "settings migration keeps the hook symlink itself" true \
    "$([ -L "$claude_target/hooks/agent-awake.sh" ] && echo true || echo false)"
rm -f "$claude_target/hooks/agent-awake.sh"
run_agent_awake_migration
assert_eq "settings migration reseeds a real file after the link is gone" false \
    "$([ -L "$claude_target/hooks/agent-awake.sh" ] && echo true || echo false)"
assert_eq "reseeded hook stays executable" true \
    "$([ -x "$claude_target/hooks/agent-awake.sh" ] && echo true || echo false)"

# Managed defaults wire all keep-awake events. (Retirement of formerly
# seeded hooks is covered by tests/claude-migrations.sh.)
assert_eq "managed defaults contain all client signal entries" 3 \
    "$(jq '[.hooks[][]?.hooks[]? | select(.command | startswith("~/.claude/hooks/agent-awake.sh "))] | length' \
        "$BOXA_DIR/config/claude/settings.json")"

# The fresh-install offer records a decline once without needing Go.
decline_output="$(printf 'n\n' | "$KEEP_AWAKE" offer --interactive)"
assert_contains "offer reports later enable command" "boxa keep-awake enable" "$decline_output"
assert_eq "decline marker is remembered" "declined" "$("$KEEP_AWAKE" probe)"
second_offer="$("$KEEP_AWAKE" offer --interactive)"
assert_eq "decided offer does not prompt again" "" "$second_offer"
refresh_disabled_output="$("$KEEP_AWAKE" refresh)"
assert_eq "refresh is silent when keep-awake is not enabled" "" "$refresh_disabled_output"

# With neither Docker nor Go available, enable prints the Docker-first remedy
# and mutates no binary, autostart, or Host connection state.
rm -f "$XDG_CONFIG_HOME/boxa/keep-awake.conf"
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
{
    printf '#!/usr/bin/env bash\n'
    printf '%s\n' 'printf "daemon %s\n" "$*" >> "$KEEP_AWAKE_TEST_LOG"'
    printf 'exit 0\n'
} > "$host_output_dir/$output_name"
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
assert_eq "enable installs Linux tray source" true \
    "$(file_exists "$TMPROOT/install/keep-awake-tray.sh")"
assert_eq "enable starts independent Linux tray unit" true \
    "$(file_exists "$KEEP_AWAKE_TEST_TRAY_SYSTEMD")"
assert_eq "enable creates global Host connection" true "$(file_exists "$KEEP_AWAKE_TEST_CONNECT")"
assert_eq "enabled elective probes OK" ok "$("$KEEP_AWAKE" probe)"
assert_contains "default enable persists system autostart mode" "autostart=system" \
    "$(cat "$XDG_CONFIG_HOME/boxa/keep-awake.conf")"
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

: > "$KEEP_AWAKE_TEST_LOG"
refresh_output="$("$KEEP_AWAKE" refresh)"
assert_eq "refresh emits no elective prompt" "" "$refresh_output"
assert_contains "refresh rebuilds the daemon binary" "docker run --rm" \
    "$(cat "$KEEP_AWAKE_TEST_LOG")"
assert_contains "refresh restarts the existing Linux service" \
    "systemctl --user restart boxa-keep-awake.service" \
    "$(cat "$KEEP_AWAKE_TEST_LOG")"
assert_not_contains "refresh does not recreate the Host connection" \
    "boxa connect host" "$(cat "$KEEP_AWAKE_TEST_LOG")"

status_output="$("$KEEP_AWAKE" status)"
assert_contains "status reports reachable daemon" "Daemon reachable: yes" "$status_output"
assert_contains "status reports active holders" '"agent":"codex"' "$status_output"
assert_contains "status reports autostart" "Autostart installed: yes" "$status_output"
assert_contains "status reports system autostart mode" "autostart: system" "$status_output"
assert_contains "status reports Host connection" "Host connection present: yes" "$status_output"
assert_contains "status reports complete client signal path" \
    "Client signal: signal path OK" "$status_output"
assert_contains "status reports Linux tray separately" "Tray: running" "$status_output"

missing_defaults="$TMPROOT/missing-claude-defaults"
mkdir -p "$missing_defaults"
missing_client_status="$(BOXA_KEEP_AWAKE_CLAUDE_DEFAULTS="$missing_defaults" \
    "$KEEP_AWAKE" status)"
assert_contains "status reports missing managed hook" \
    "managed hook file" "$missing_client_status"
assert_contains "status reports missing managed settings" \
    "managed settings file" "$missing_client_status"

disable_output="$("$KEEP_AWAKE" disable)"
assert_contains "disable reports all reversed components" \
    "daemon stopped, autostart removed, Host connection removed" "$disable_output"
assert_eq "disable removes binary" false "$(file_exists "$TMPROOT/install/keep-awake")"
assert_eq "disable removes Linux autostart" false "$(file_exists "$KEEP_AWAKE_TEST_SYSTEMD")"
assert_eq "disable removes Linux tray source" false \
    "$(file_exists "$TMPROOT/install/keep-awake-tray.sh")"
assert_eq "disable stops Linux tray unit" false \
    "$(file_exists "$KEEP_AWAKE_TEST_TRAY_SYSTEMD")"
assert_eq "disable removes Host connection" false "$(file_exists "$KEEP_AWAKE_TEST_CONNECT")"
assert_eq "disable records deliberate opt-out" declined "$("$KEEP_AWAKE" probe)"
export KEEP_AWAKE_TEST_CURL_HEALTHY=false
disabled_status="$("$KEEP_AWAKE" status)"
assert_contains "disabled status reports daemon down" "Daemon reachable: no" "$disabled_status"
assert_contains "disabled status reports autostart absent" "Autostart installed: no" "$disabled_status"
assert_contains "disabled status reports Host connection absent" "Host connection present: no" "$disabled_status"
assert_contains "disabled status reports unreachable client signal daemon" \
    "Client signal: missing reachable daemon" "$disabled_status"
assert_contains "disabled status reports tray not installed" "Tray: not installed" "$disabled_status"
export KEEP_AWAKE_TEST_CURL_HEALTHY=true

# Terminal and none modes start the daemon without system or tray autostart.
# Terminal prints resolved WezTerm argv; none leaves startup entirely to the
# user. Both remain healthy according to the elective probe.
rm -f "$XDG_CONFIG_HOME/boxa/keep-awake.conf"
: > "$KEEP_AWAKE_TEST_LOG"
terminal_output="$("$KEEP_AWAKE" enable --autostart terminal)"
assert_eq "terminal mode installs no Linux autostart" false \
    "$(file_exists "$KEEP_AWAKE_TEST_SYSTEMD")"
assert_eq "terminal mode installs no tray autostart" false \
    "$(file_exists "$KEEP_AWAKE_TEST_TRAY_SYSTEMD")"
assert_contains "terminal mode prints WezTerm gui-startup hook" \
    "wezterm.on('gui-startup'" "$terminal_output"
assert_contains "Linux terminal snippet uses resolved binary path" \
    "$TMPROOT/install/keep-awake" "$terminal_output"
assert_contains "Linux terminal snippet keeps daemon port argument" \
    "'-port', '17777'" "$terminal_output"
assert_contains "Linux terminal snippet keeps resolved log path" \
    "$XDG_STATE_HOME/boxa/keep-awake/keep-awake.log" "$terminal_output"
assert_contains "terminal mode starts daemon immediately" \
    "daemon -port 17777 -log-file $XDG_STATE_HOME/boxa/keep-awake/keep-awake.log" \
    "$(cat "$KEEP_AWAKE_TEST_LOG")"
assert_contains "terminal mode is persisted" "autostart=terminal" \
    "$(cat "$XDG_CONFIG_HOME/boxa/keep-awake.conf")"
terminal_status="$("$KEEP_AWAKE" status)"
assert_contains "terminal status reports selected mode" "autostart: terminal" \
    "$terminal_status"
assert_contains "terminal status explains absent tray" \
    "Tray: not installed (autostart: terminal)" "$terminal_status"
assert_eq "terminal mode probes OK without system autostart" ok "$("$KEEP_AWAKE" probe)"
terminal_disable="$("$KEEP_AWAKE" disable)"
assert_contains "terminal disable reminds user to remove WezTerm block" \
    "Remove the Boxa keep-awake gui-startup block" "$terminal_disable"

rm -f "$XDG_CONFIG_HOME/boxa/keep-awake.conf"
: > "$KEEP_AWAKE_TEST_LOG"
none_output="$("$KEEP_AWAKE" enable --autostart none)"
assert_eq "none mode installs no Linux autostart" false \
    "$(file_exists "$KEEP_AWAKE_TEST_SYSTEMD")"
assert_eq "none mode installs no tray autostart" false \
    "$(file_exists "$KEEP_AWAKE_TEST_TRAY_SYSTEMD")"
assert_not_contains "none mode prints no WezTerm snippet" "gui-startup" "$none_output"
assert_contains "none mode starts daemon immediately" \
    "daemon -port 17777 -log-file $XDG_STATE_HOME/boxa/keep-awake/keep-awake.log" \
    "$(cat "$KEEP_AWAKE_TEST_LOG")"
assert_contains "none mode is persisted" "autostart=none" \
    "$(cat "$XDG_CONFIG_HOME/boxa/keep-awake.conf")"
none_status="$("$KEEP_AWAKE" status)"
assert_contains "none status reports selected mode" "autostart: none" "$none_status"
assert_contains "none status explains absent tray" \
    "Tray: not installed (autostart: none)" "$none_status"
assert_eq "none mode probes OK without system autostart" ok "$("$KEEP_AWAKE" probe)"

# In none mode the daemon belongs to the user's own start mechanism, possibly
# with custom arguments: refresh swaps the binary in place and stops there, so
# it can never miss that process on stop nor race a default instance onto the
# port. The running process keeps the old inode until the user restarts it.
printf '# stale-binary-marker\n' >> "$TMPROOT/install/keep-awake"
: > "$KEEP_AWAKE_TEST_LOG"
none_refresh_output="$("$KEEP_AWAKE" refresh)"
assert_contains "none refresh rebuilds the daemon binary" "docker run --rm" \
    "$(cat "$KEEP_AWAKE_TEST_LOG")"
assert_not_contains "none refresh replaces the installed binary" \
    "stale-binary-marker" "$(cat "$TMPROOT/install/keep-awake")"
assert_not_contains "none refresh starts no competing daemon" "daemon -port" \
    "$(cat "$KEEP_AWAKE_TEST_LOG")"
assert_contains "none refresh asks the user to restart their own daemon" \
    "restart the user-managed daemon with your own mechanism" \
    "$none_refresh_output"
"$KEEP_AWAKE" disable >/dev/null

# Missing Linux tray prerequisites and tray startup failures are notices only;
# the daemon remains fully enabled and the tray has its own status.
mv "$TMPROOT/bin/yad" "$TMPROOT/bin/yad.mock"
rm -f "$XDG_CONFIG_HOME/boxa/keep-awake.conf"
missing_yad_output="$(PATH="$TMPROOT/bin:/usr/bin:/bin" "$KEEP_AWAKE" enable 2>&1)"
assert_contains "missing yad prints package remedy" "Install the yad package" "$missing_yad_output"
assert_eq "missing yad still enables daemon" ok \
    "$(PATH="$TMPROOT/bin:/usr/bin:/bin" "$KEEP_AWAKE" probe)"
assert_eq "missing yad installs no tray source" false \
    "$(file_exists "$TMPROOT/install/keep-awake-tray.sh")"
missing_yad_status="$(PATH="$TMPROOT/bin:/usr/bin:/bin" "$KEEP_AWAKE" status)"
assert_contains "status reports missing Linux tray prerequisite" \
    "Tray: skipped-missing-prereq" "$missing_yad_status"
PATH="$TMPROOT/bin:/usr/bin:/bin" "$KEEP_AWAKE" disable >/dev/null
mv "$TMPROOT/bin/yad.mock" "$TMPROOT/bin/yad"

rm -f "$XDG_CONFIG_HOME/boxa/keep-awake.conf"
export KEEP_AWAKE_TEST_TRAY_START_FAIL=true
tray_failure_output="$("$KEEP_AWAKE" enable 2>&1)"
assert_contains "tray startup failure is reported as optional" \
    "daemon remains enabled without the optional tray" "$tray_failure_output"
assert_eq "tray startup failure still enables daemon" ok "$("$KEEP_AWAKE" probe)"
assert_eq "tray startup failure cleans partial artifacts" false \
    "$(file_exists "$TMPROOT/install/keep-awake-tray.sh")"
assert_contains "failed tray status is not installed" "Tray: not installed" \
    "$("$KEEP_AWAKE" status)"
export KEEP_AWAKE_TEST_TRAY_START_FAIL=false
"$KEEP_AWAKE" disable >/dev/null

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
{
    printf '#!/usr/bin/env bash\n'
    printf '%s\n' 'printf "daemon %s\n" "$*" >> "$KEEP_AWAKE_TEST_LOG"'
    printf 'exit 0\n'
} > "$output"
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

# A post-start Host connection failure keeps the daemon, autostart, and state
# installed; only the connection is reported for retry (issue 15).
rm -f "$XDG_CONFIG_HOME/boxa/keep-awake.conf"
export KEEP_AWAKE_TEST_CONNECT_FAIL=true
partial_rc=0
partial_output="$("$KEEP_AWAKE" enable 2>&1)" || partial_rc=$?
assert_contains "connect failure reports kept install" \
    "daemon, autostart, and tray stay installed" "$partial_output"
assert_contains "connect failure advises retry" \
    're-run "boxa keep-awake enable"' "$partial_output"
assert_eq "connect failure exits non-zero" 1 "$partial_rc"
assert_eq "connect failure keeps binary" true "$(file_exists "$TMPROOT/install/keep-awake")"
assert_eq "connect failure keeps autostart" true "$(file_exists "$KEEP_AWAKE_TEST_SYSTEMD")"
assert_contains "connect failure records enabled state" "enabled=true" \
    "$(cat "$XDG_CONFIG_HOME/boxa/keep-awake.conf" 2>/dev/null || true)"
assert_contains "connect failure records incomplete connection" "connection=incomplete" \
    "$(cat "$XDG_CONFIG_HOME/boxa/keep-awake.conf" 2>/dev/null || true)"
assert_eq "incomplete connection keeps probe unconverged" missing "$("$KEEP_AWAKE" probe)"
assert_contains "incomplete connection surfaces in status" \
    "incomplete (re-run: boxa keep-awake enable)" "$("$KEEP_AWAKE" status)"
export KEEP_AWAKE_TEST_CONNECT_FAIL=false
"$KEEP_AWAKE" enable >/dev/null
assert_eq "successful retry restores probe ok" ok "$("$KEEP_AWAKE" probe)"
"$KEEP_AWAKE" disable >/dev/null

# Uninstall teardown stops daemon/autostart and removes its marker while
# deliberately leaving the Host connection to docker-run.sh's existing sweep.
"$KEEP_AWAKE" enable >/dev/null
"$KEEP_AWAKE" teardown --keep-connection --remove-state
assert_eq "uninstall teardown removes binary" false "$(file_exists "$TMPROOT/install/keep-awake")"
assert_eq "uninstall teardown removes autostart" false "$(file_exists "$KEEP_AWAKE_TEST_SYSTEMD")"
assert_eq "uninstall teardown removes tray unit" false \
    "$(file_exists "$KEEP_AWAKE_TEST_TRAY_SYSTEMD")"
assert_eq "uninstall teardown removes tray artifacts" false \
    "$(file_exists "$TMPROOT/install/keep-awake-tray.sh")"
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
assert_eq "macOS enable compiles tray beside daemon" true \
    "$(file_exists "$TMPROOT/macos-install/keep-awake-tray")"
assert_eq "macOS enable bootstraps separate tray agent" true \
    "$(file_exists "$KEEP_AWAKE_TEST_TRAY_LAUNCHD")"
assert_contains "macOS launchd command is user-scoped" "launchctl bootstrap gui/" "$(cat "$KEEP_AWAKE_TEST_LOG")"
assert_contains "macOS status reports tray separately" "Tray: running" \
    "$("$KEEP_AWAKE" status)"
"$KEEP_AWAKE" disable >/dev/null
assert_eq "macOS disable removes launchd user agent" false "$(file_exists "$KEEP_AWAKE_TEST_LAUNCHD")"
assert_eq "macOS disable removes tray agent" false \
    "$(file_exists "$KEEP_AWAKE_TEST_TRAY_LAUNCHD")"
assert_eq "macOS disable removes compiled tray" false \
    "$(file_exists "$TMPROOT/macos-install/keep-awake-tray")"

rm -f "$XDG_CONFIG_HOME/boxa/keep-awake.conf"
mv "$TMPROOT/bin/swiftc" "$TMPROOT/bin/swiftc.mock"
missing_swift_output="$(PATH="$TMPROOT/bin:/usr/bin:/bin" "$KEEP_AWAKE" enable 2>&1)"
assert_contains "missing swiftc prints Xcode CLT remedy" \
    "xcode-select --install" "$missing_swift_output"
assert_eq "missing swiftc still enables daemon" ok \
    "$(PATH="$TMPROOT/bin:/usr/bin:/bin" "$KEEP_AWAKE" probe)"
missing_swift_status="$(PATH="$TMPROOT/bin:/usr/bin:/bin" "$KEEP_AWAKE" status)"
assert_contains "status reports missing macOS tray prerequisite" \
    "Tray: skipped-missing-prereq" "$missing_swift_status"
PATH="$TMPROOT/bin:/usr/bin:/bin" "$KEEP_AWAKE" disable >/dev/null
mv "$TMPROOT/bin/swiftc.mock" "$TMPROOT/bin/swiftc"

rm -f "$XDG_CONFIG_HOME/boxa/keep-awake.conf"
export BOXA_KEEP_AWAKE_PLATFORM=wsl2
export BOXA_KEEP_AWAKE_INSTALL_DIR="$TMPROOT/windows-install"
export WSL_DISTRO_NAME=Ubuntu-Boxa-Test
"$KEEP_AWAKE" enable >/dev/null
assert_eq "Windows enable creates firewall rule" true \
    "$(file_exists "$KEEP_AWAKE_TEST_FIREWALL_RULE")"
assert_contains "Windows firewall rule is TCP-only" "-Protocol TCP" \
    "$(cat "$KEEP_AWAKE_TEST_LOG")"
assert_contains "Windows firewall rule uses the keep-awake port" "-LocalPort '17777'" \
    "$(cat "$KEEP_AWAKE_TEST_LOG")"
assert_contains "Windows firewall rule is limited to WSL interfaces" \
    "-InterfaceAlias \$interfaces" "$(cat "$KEEP_AWAKE_TEST_LOG")"
assert_contains "Windows firewall rule is limited to the interface subnet" \
    "-RemoteAddress LocalSubnet" "$(cat "$KEEP_AWAKE_TEST_LOG")"
firewall_creates_before="$(grep -c 'New-NetFirewallRule' "$KEEP_AWAKE_TEST_LOG")"
"$KEEP_AWAKE" enable >/dev/null
assert_eq "repeated Windows enable does not duplicate firewall rule" \
    "$firewall_creates_before" "$(grep -c 'New-NetFirewallRule' "$KEEP_AWAKE_TEST_LOG")"
windows_loopback_status="$("$KEEP_AWAKE" status)"
assert_contains "WSL status selects responding loopback first" \
    "Relay target: loopback (127.0.0.1)" "$windows_loopback_status"
assert_contains "WSL status reports firewall rule name and presence" \
    "Windows firewall rule: present (Boxa Keep-Awake (WSL))" \
    "$windows_loopback_status"
mkdir -p "$XDG_STATE_HOME/boxa/host-connections"
printf '127.0.0.2\t12345\t\tfalse\tgateway\t172.30.96.1\n' \
    > "$XDG_STATE_HOME/boxa/host-connections/17777.state"
assert_contains "WSL status reports the active relay state target" \
    "Relay target: gateway (172.30.96.1)" "$("$KEEP_AWAKE" status)"
rm -f "$XDG_STATE_HOME/boxa/host-connections/17777.state"
export KEEP_AWAKE_TEST_LOOPBACK_HEALTHY=false
printf 'candidate-probe-start\n' >> "$KEEP_AWAKE_TEST_LOG"
windows_gateway_status="$("$KEEP_AWAKE" status)"
assert_contains "WSL status falls back to responding gateway" \
    "Relay target: gateway (172.30.96.1)" "$windows_gateway_status"
assert_eq "WSL doctor probe uses gateway candidate" ok "$("$KEEP_AWAKE" probe)"
assert_eq "WSL target probe tries loopback before gateway" \
    $'http://127.0.0.1:17777/v1/status\nhttp://172.30.96.1:17777/v1/status' \
    "$(awk '/^candidate-probe-start$/ { capture=1; next }
        capture && /^status / { sub(/^status /, ""); print }' \
        "$KEEP_AWAKE_TEST_LOG" | head -n2)"
export KEEP_AWAKE_TEST_GATEWAY_HEALTHY=false
windows_unreachable_status="$("$KEEP_AWAKE" status)"
assert_contains "WSL status reports no responding candidate" \
    "Relay target: unreachable" "$windows_unreachable_status"
assert_eq "WSL doctor probe rejects all unreachable candidates" missing \
    "$("$KEEP_AWAKE" probe)"

# heal-firewall is the self-heal seam for an unreachable daemon: it refuses
# every situation in which elevating would be pointless, so a plain start never
# pays for it.
assert_eq "heal-firewall declines while the rule is present" declined \
    "$("$KEEP_AWAKE" heal-firewall >/dev/null 2>&1 && printf healed || printf declined)"
rm -f "$KEEP_AWAKE_TEST_FIREWALL_RULE"
export KEEP_AWAKE_TEST_DAEMON_PROCESS=false
heal_elevations_before="$(grep -c 'New-NetFirewallRule' "$KEEP_AWAKE_TEST_LOG")"
assert_eq "heal-firewall declines while the daemon is not running" declined \
    "$("$KEEP_AWAKE" heal-firewall >/dev/null 2>&1 && printf healed || printf declined)"
assert_eq "heal-firewall does not elevate for a stopped daemon" \
    "$heal_elevations_before" \
    "$(grep -c 'New-NetFirewallRule' "$KEEP_AWAKE_TEST_LOG")"
export KEEP_AWAKE_TEST_DAEMON_PROCESS=true
assert_eq "heal-firewall installs the rule a running daemon needs" healed \
    "$("$KEEP_AWAKE" heal-firewall >/dev/null 2>&1 && printf healed || printf declined)"
assert_eq "heal-firewall leaves the rule in place" true \
    "$(file_exists "$KEEP_AWAKE_TEST_FIREWALL_RULE")"
rm -f "$KEEP_AWAKE_TEST_FIREWALL_RULE"
assert_eq "heal-firewall honours the harness opt-out" declined \
    "$(BOXA_KEEP_AWAKE_SKIP_FIREWALL_HEAL=1 "$KEEP_AWAKE" heal-firewall \
        >/dev/null 2>&1 && printf healed || printf declined)"
assert_eq "opt-out heal creates no rule" false \
    "$(file_exists "$KEEP_AWAKE_TEST_FIREWALL_RULE")"
"$KEEP_AWAKE" heal-firewall >/dev/null 2>&1 || true
export KEEP_AWAKE_TEST_LOOPBACK_HEALTHY=true
export KEEP_AWAKE_TEST_GATEWAY_HEALTHY=true
assert_eq "Windows enable creates scheduled task" true "$(file_exists "$KEEP_AWAKE_TEST_TASK")"
assert_eq "Windows enable creates separate tray task" true \
    "$(file_exists "$KEEP_AWAKE_TEST_TRAY_TASK")"
assert_contains "Windows task is scheduled at logon" "/SC ONLOGON" "$(cat "$KEEP_AWAKE_TEST_LOG")"
assert_contains "Windows tray task is scheduled at logon" \
    "/Create /TN BoxaKeepAwakeTray /SC ONLOGON" "$(cat "$KEEP_AWAKE_TEST_LOG")"
windows_tray="$TMPROOT/windows-install/keep-awake-tray.ps1"
assert_eq "Windows tray script is installed beside daemon" true "$(file_exists "$windows_tray")"
assert_contains "Windows tray polls versioned status endpoint" \
    "http://localhost:\$Port/v1/status" "$(cat "$windows_tray")"
assert_contains "Windows tray uses inhibition state" 'status.isInhibited' "$(cat "$windows_tray")"
assert_contains "Windows tray lists active holders" 'Status.activeHolders' "$(cat "$windows_tray")"
assert_contains "Windows tray keeps single-instance mutex" \
    'Local\BoxaKeepAwakeTray' "$(cat "$windows_tray")"
assert_contains "Windows tray keeps crash log trap" "Tray CRASHED" "$(cat "$windows_tray")"
assert_contains "Windows status reports tray separately" "Tray: running" \
    "$("$KEEP_AWAKE" status)"
windows_wrapper="$TMPROOT/windows-install/start-keep-awake.ps1"
assert_eq "Windows task installs runtime gateway wrapper" true "$(file_exists "$windows_wrapper")"
assert_contains "Windows wrapper passes the installing WSL distribution" \
    "\$env:BOXA_WSL_DISTRO = 'Ubuntu-Boxa-Test'" "$(cat "$windows_wrapper")"
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
    "$(grep -c '172\.30\.96\.1' "$windows_wrapper" || true)"
assert_contains "Windows Docker build targets Windows" \
    "--env GOOS=windows" "$(cat "$KEEP_AWAKE_TEST_LOG")"
assert_contains "Windows Docker build uses GUI subsystem" \
    "-ldflags -H=windowsgui" "$(cat "$KEEP_AWAKE_TEST_LOG")"
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
assert_eq "Windows disable deletes tray task" false \
    "$(file_exists "$KEEP_AWAKE_TEST_TRAY_TASK")"
assert_eq "Windows disable removes runtime gateway wrapper" false "$(file_exists "$windows_wrapper")"
assert_eq "Windows disable removes tray script" false "$(file_exists "$windows_tray")"
assert_eq "Windows disable removes firewall rule" false \
    "$(file_exists "$KEEP_AWAKE_TEST_FIREWALL_RULE")"
assert_contains "Windows firewall removal uses Remove-NetFirewallRule" \
    "Remove-NetFirewallRule" "$(cat "$KEEP_AWAKE_TEST_LOG")"

# UAC cancellation is survivable even under NAT: installation remains enabled,
# while status and doctor identify the absent Windows rule as the likely cause.
rm -f "$XDG_CONFIG_HOME/boxa/keep-awake.conf"
: > "$KEEP_AWAKE_TEST_LOG"
export KEEP_AWAKE_TEST_FIREWALL_ELEVATION=decline
export KEEP_AWAKE_TEST_LOOPBACK_HEALTHY=false
export KEEP_AWAKE_TEST_GATEWAY_HEALTHY=false
export KEEP_AWAKE_TEST_CONNECT_FAIL=true
export KEEP_AWAKE_TEST_DAEMON_PROCESS=true
declined_firewall_rc=0
declined_firewall_output="$("$KEEP_AWAKE" enable 2>&1)" || declined_firewall_rc=$?
assert_eq "declined firewall elevation keeps enable successful" 0 "$declined_firewall_rc"
assert_contains "declined firewall elevation warns that NAT stays blocked" \
    "WSL NAT path to TCP port 17777 stays blocked" "$declined_firewall_output"
assert_contains "declined firewall elevation preserves mirrored loopback" \
    "Mirrored networking/loopback keeps working" "$declined_firewall_output"
assert_eq "declined firewall elevation creates no rule" false \
    "$(file_exists "$KEEP_AWAKE_TEST_FIREWALL_RULE")"
declined_firewall_status="$("$KEEP_AWAKE" status)"
assert_contains "status reports absent firewall rule by name" \
    "Windows firewall rule: absent (Boxa Keep-Awake (WSL))" \
    "$declined_firewall_status"
assert_contains "status diagnoses absent firewall rule for running daemon" \
    'missing Windows firewall rule "Boxa Keep-Awake (WSL)" is the likely cause' \
    "$declined_firewall_status"
assert_contains "doctor diagnoses absent firewall rule for running daemon" \
    'missing Windows firewall rule "Boxa Keep-Awake (WSL)" is the likely cause' \
    "$("$KEEP_AWAKE" doctor)"

doctor_cli_dir="$TMPROOT/keep-awake-doctor-cli"
mkdir -p "$doctor_cli_dir/lib" "$doctor_cli_dir/scripts"
cp "$BOXA_DIR/docker-run.sh" "$doctor_cli_dir/docker-run.sh"
cp -R "$BOXA_DIR/lib/." "$doctor_cli_dir/lib/"
cp "$KEEP_AWAKE" "$doctor_cli_dir/scripts/ensure-keep-awake.sh"
cat > "$doctor_cli_dir/lib/provisioning.sh" <<'EOF'
#!/usr/bin/env bash
BOXA_PROVISIONING_STEPS=("keep-awake|scripts/ensure-keep-awake.sh|B")
boxa::run_provisioning() {
    BOXA_PROVISIONING_REPAIRED=()
    BOXA_PROVISIONING_OK=()
    BOXA_PROVISIONING_SKIPPED=()
    BOXA_PROVISIONING_PREREQ_MISSING=()
    BOXA_PROVISIONING_MISSING=("keep-awake")
    BOXA_PROVISIONING_DECLINED=()
    BOXA_PROVISIONING_FAILED=()
}
boxa::prereq_remedy() { :; }
EOF
chmod +x "$doctor_cli_dir/docker-run.sh" \
    "$doctor_cli_dir/scripts/ensure-keep-awake.sh"
rm -f "$KEEP_AWAKE_TEST_CONNECT"
boxa_doctor_output="$(BOXA_DIR="$doctor_cli_dir" \
    bash "$doctor_cli_dir/docker-run.sh" doctor 2>&1 || true)"
assert_contains "boxa doctor reports absent firewall rule by name" \
    "Windows firewall rule: absent (Boxa Keep-Awake (WSL))" \
    "$boxa_doctor_output"
assert_contains "boxa doctor names absent firewall rule as likely cause" \
    'missing Windows firewall rule "Boxa Keep-Awake (WSL)" is the likely cause' \
    "$boxa_doctor_output"
export KEEP_AWAKE_TEST_FIREWALL_ELEVATION=success
export KEEP_AWAKE_TEST_LOOPBACK_HEALTHY=true
export KEEP_AWAKE_TEST_GATEWAY_HEALTHY=true
export KEEP_AWAKE_TEST_CONNECT_FAIL=false
export KEEP_AWAKE_TEST_DAEMON_PROCESS=false
"$KEEP_AWAKE" disable >/dev/null

# Uninstall teardown owns the same best-effort elevated firewall cleanup.
rm -f "$XDG_CONFIG_HOME/boxa/keep-awake.conf"
"$KEEP_AWAKE" enable >/dev/null
"$KEEP_AWAKE" teardown --keep-connection --remove-state >/dev/null
assert_eq "Windows uninstall teardown removes firewall rule" false \
    "$(file_exists "$KEEP_AWAKE_TEST_FIREWALL_RULE")"
rm -f "$KEEP_AWAKE_TEST_CONNECT"

rm -f "$XDG_CONFIG_HOME/boxa/keep-awake.conf"
: > "$KEEP_AWAKE_TEST_LOG"
windows_terminal_output="$("$KEEP_AWAKE" enable --autostart terminal)"
assert_eq "Windows terminal mode creates no daemon task" false \
    "$(file_exists "$KEEP_AWAKE_TEST_TASK")"
assert_eq "Windows terminal mode creates no tray task" false \
    "$(file_exists "$KEEP_AWAKE_TEST_TRAY_TASK")"
assert_contains "Windows terminal mode retains generated wrapper" \
    "Get-WslGateway" "$(cat "$windows_wrapper")"
assert_contains "Windows terminal snippet launches PowerShell" \
    "'powershell.exe'" "$windows_terminal_output"
assert_contains "Windows terminal snippet hides its window" \
    "'-WindowStyle', 'Hidden'" "$windows_terminal_output"
assert_contains "Windows terminal snippet uses resolved wrapper path" \
    'C:\\Boxa\\start-keep-awake.ps1' "$windows_terminal_output"
assert_not_contains "Windows terminal snippet never launches raw executable" \
    'keep-awake.exe' "$windows_terminal_output"
assert_contains "Windows terminal snippet passes tray follow target" \
    "'-TrayFollow', 'wezterm-gui'" "$windows_terminal_output"
assert_eq "Windows terminal mode installs tray script" true \
    "$(file_exists "$windows_tray")"
assert_contains "Windows terminal tray follows terminal process" \
    "Get-Process -Name \$FollowProcess" "$(cat "$windows_tray")"
assert_contains "Windows terminal enable starts tray immediately" \
    "'17777', 'wezterm-gui'" "$(cat "$KEEP_AWAKE_TEST_LOG")"
assert_contains "Windows terminal wrapper accepts tray follow parameter" \
    "param([string]\$TrayFollow" "$(cat "$windows_wrapper")"
assert_contains "Windows terminal wrapper spawns tray only when following" \
    "if (\$TrayFollow -and (Test-Path -LiteralPath \$trayFile))" "$(cat "$windows_wrapper")"
assert_contains "Windows terminal status reports dormant tray" \
    "Tray: not running (starts with WezTerm)" "$("$KEEP_AWAKE" status)"
export KEEP_AWAKE_TEST_TRAY_PROCESS=true
assert_contains "Windows terminal status reports live tray" \
    "Tray: running" "$("$KEEP_AWAKE" status)"
export KEEP_AWAKE_TEST_TRAY_PROCESS=false
"$KEEP_AWAKE" disable >/dev/null
assert_eq "Windows terminal disable removes tray script" false \
    "$(file_exists "$windows_tray")"
assert_contains "Windows terminal disable stops running tray" \
    "Stop-Process" "$(cat "$KEEP_AWAKE_TEST_LOG")"

# Switching terminal -> system must clear the process-following tray first,
# or it would hold the single-instance mutex and starve the scheduled tray.
rm -f "$XDG_CONFIG_HOME/boxa/keep-awake.conf"
"$KEEP_AWAKE" enable --autostart terminal >/dev/null
: > "$KEEP_AWAKE_TEST_LOG"
"$KEEP_AWAKE" enable >/dev/null
assert_contains "Windows system enable stops leftover terminal tray" \
    "Stop-Process" "$(cat "$KEEP_AWAKE_TEST_LOG")"
assert_eq "Windows system enable recreates tray task" true \
    "$(file_exists "$KEEP_AWAKE_TEST_TRAY_TASK")"
"$KEEP_AWAKE" disable >/dev/null

rm -f "$XDG_CONFIG_HOME/boxa/keep-awake.conf"
: > "$KEEP_AWAKE_TEST_LOG"
export KEEP_AWAKE_TEST_DOCKER_FAIL=true
"$KEEP_AWAKE" enable --autostart none >/dev/null 2>&1
windows_local_build_log="$(grep '^go ' "$KEEP_AWAKE_TEST_LOG")"
assert_contains "Windows local Go build targets Windows" "GOOS=windows" \
    "$windows_local_build_log"
assert_contains "Windows local Go build uses GUI subsystem" \
    "-ldflags -H=windowsgui" "$windows_local_build_log"
"$KEEP_AWAKE" disable >/dev/null
export KEEP_AWAKE_TEST_DOCKER_FAIL=false

# Windows cannot swap a running .exe, so a WSL2 refresh stops the daemon before
# installing. A failing install must not leave the host daemon-less: the old,
# untouched binary is started again the way its autostart mode owns it, while
# the failure itself is still reported and non-zero.
cat > "$TMPROOT/bin/install" <<'EOF'
#!/usr/bin/env bash
if [ "${KEEP_AWAKE_TEST_INSTALL_FAIL:-false}" = true ]; then
    printf 'install-refused %s\n' "$*" >> "$KEEP_AWAKE_TEST_LOG"
    exit 1
fi
exec /usr/bin/install "$@"
EOF
chmod +x "$TMPROOT/bin/install"
export KEEP_AWAKE_TEST_INSTALL_FAIL=false

rm -f "$XDG_CONFIG_HOME/boxa/keep-awake.conf"
"$KEEP_AWAKE" enable >/dev/null
: > "$KEEP_AWAKE_TEST_LOG"
export KEEP_AWAKE_TEST_INSTALL_FAIL=true
wsl_refresh_rc=0
wsl_refresh_output="$("$KEEP_AWAKE" refresh 2>&1)" || wsl_refresh_rc=$?
export KEEP_AWAKE_TEST_INSTALL_FAIL=false
assert_eq "failed Windows refresh install keeps failing" 1 "$wsl_refresh_rc"
assert_contains "failed Windows refresh reports the installation failure" \
    "refreshed binary installation failed" "$wsl_refresh_output"
assert_contains "failed Windows system refresh reruns the old scheduled task" \
    "schtasks /Run /TN BoxaKeepAwake" "$(cat "$KEEP_AWAKE_TEST_LOG")"
"$KEEP_AWAKE" disable >/dev/null

rm -f "$XDG_CONFIG_HOME/boxa/keep-awake.conf"
"$KEEP_AWAKE" enable --autostart terminal >/dev/null
# The wrapper is rewritten by every direct start, so its return proves the old
# daemon was launched again after the failed swap.
rm -f "$windows_wrapper"
: > "$KEEP_AWAKE_TEST_LOG"
export KEEP_AWAKE_TEST_INSTALL_FAIL=true
wsl_terminal_refresh_rc=0
"$KEEP_AWAKE" refresh >/dev/null 2>&1 || wsl_terminal_refresh_rc=$?
export KEEP_AWAKE_TEST_INSTALL_FAIL=false
assert_eq "failed Windows terminal refresh keeps failing" 1 \
    "$wsl_terminal_refresh_rc"
assert_eq "failed Windows terminal refresh restarts the old daemon directly" \
    true "$(file_exists "$windows_wrapper")"
"$KEEP_AWAKE" disable >/dev/null

rm -f "$XDG_CONFIG_HOME/boxa/keep-awake.conf"
"$KEEP_AWAKE" enable --autostart none >/dev/null
: > "$KEEP_AWAKE_TEST_LOG"
windows_none_refresh_output="$("$KEEP_AWAKE" refresh)"
assert_contains "Windows none refresh reports the swap-forced stop" \
    "stopped for the Windows binary swap" "$windows_none_refresh_output"
assert_not_contains "Windows none refresh reruns no boxa-owned autostart" \
    "schtasks /Run" "$(cat "$KEEP_AWAKE_TEST_LOG")"
: > "$KEEP_AWAKE_TEST_LOG"
export KEEP_AWAKE_TEST_INSTALL_FAIL=true
windows_none_refresh_rc=0
windows_none_failure="$("$KEEP_AWAKE" refresh 2>&1)" || windows_none_refresh_rc=$?
export KEEP_AWAKE_TEST_INSTALL_FAIL=false
assert_eq "failed Windows none refresh keeps failing" 1 \
    "$windows_none_refresh_rc"
assert_contains "failed Windows none refresh leaves the restart to the user" \
    "start it again with your own mechanism" "$windows_none_failure"
assert_not_contains "failed Windows none refresh starts no boxa-owned daemon" \
    "schtasks /Run" "$(cat "$KEEP_AWAKE_TEST_LOG")"
"$KEEP_AWAKE" disable >/dev/null

# Public CLI routes the lifecycle subcommands to the canonical helper and exposes
# dedicated help without requiring Docker.
export BOXA_KEEP_AWAKE_PLATFORM=linux
export BOXA_KEEP_AWAKE_INSTALL_DIR="$TMPROOT/cli-install"
cli_help="$(bash "$BOXA_DIR/docker-run.sh" keep-awake --help)"
assert_contains "CLI help documents enable/refresh/disable/status" \
    "Usage: boxa keep-awake <enable|refresh|disable|status> [options]" "$cli_help"
assert_contains "CLI help documents autostart modes" \
    "--autostart <system|terminal|none>" "$cli_help"
assert_contains "CLI help documents the Docker-first build" \
    "pinned golang Docker container" "$cli_help"
cli_status="$(bash "$BOXA_DIR/docker-run.sh" keep-awake status)"
assert_contains "CLI status reaches canonical helper" "Daemon reachable: yes" "$cli_status"
rm -f "$XDG_CONFIG_HOME/boxa/keep-awake.conf"
cli_none_output="$(bash "$BOXA_DIR/docker-run.sh" keep-awake enable --autostart none)"
assert_contains "CLI routes enable autostart option" "autostart none" "$cli_none_output"
"$KEEP_AWAKE" disable >/dev/null

if [ "$fail_count" -gt 0 ]; then
    printf '\n%d test(s) failed.\n' "$fail_count"
    exit 1
fi

printf '\nAll keep-awake tests passed.\n'
