#!/bin/bash
# Plain-bash assertions for the SSH gate and docker-run forwarding block.
# Usage: bash tests/ssh.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOXA_DIR="$SCRIPT_DIR/.."
# shellcheck source-path=SCRIPTDIR source=../lib/resources.sh disable=SC1091
source "$BOXA_DIR/lib/resources.sh"
# shellcheck source-path=SCRIPTDIR source=../lib/ssh.sh disable=SC1091
source "$BOXA_DIR/lib/ssh.sh"

_TMPROOT="$(mktemp -d)"
export BOXA_SSH_CONF="$_TMPROOT/ssh.conf"
forwarding_block="$_TMPROOT/forwarding.sh"
sed -n '/^# SSH agent forwarding:/,/^# Pass through API key/p' \
    "$BOXA_DIR/docker-run.sh" | sed '$d' > "$forwarding_block"

agent_socket="$_TMPROOT/agent.sock"
agent_output="$(ssh-agent -a "$agent_socket" -s)"
agent_pid="$(printf '%s\n' "$agent_output" \
    | sed -n 's/^SSH_AGENT_PID=\([0-9][0-9]*\);.*/\1/p')"

cleanup() {
    [ -z "$agent_pid" ] || kill "$agent_pid" 2>/dev/null || true
    rm -rf "$(_boxa::test_tmp_root)"
}

_boxa::test_tmp_root() {
    printf '%s\n' "$_TMPROOT"
}

trap cleanup EXIT

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

assert_file_eq() {
    local label="$1" expected="$2" actual="$3"
    if cmp -s "$expected" "$actual"; then
        printf 'PASS  %s\n' "$label"
    else
        printf 'FAIL  %s\n' "$label"
        fail_count=$((fail_count + 1))
    fi
}

seed_conf() {
    : > "$BOXA_SSH_CONF"
    local line
    for line in "$@"; do
        printf '%s\n' "$line" >> "$BOXA_SSH_CONF"
    done
}

resolve_gate() {
    _boxa::resolve_ssh_gate "$1"
    printf '%s\n' "$_BOXA_SSH_GATE"
}

ssh-add() {
    printf '%s\n' "${BOXA_TEST_SSH_ADD_OUTPUT:-}"
    return "${BOXA_TEST_SSH_ADD_RC:-1}"
}

run_forwarding() {
    local project_path="$1" socket_path="$2"
    # Referenced by the dynamically sourced docker-run.sh forwarding block.
    # shellcheck disable=SC2034
    PROJECT_PATH="$project_path"
    # shellcheck disable=SC2034
    SSH_AUTH_SOCK="$socket_path"
    DOCKER_ARGS=()
    SSH_WARNING=""
    SSH_STATUS=""
    # shellcheck source=/dev/null
    source "$forwarding_block"
    DOCKER_ARGS_TEXT="$(printf '%s\n' "${DOCKER_ARGS[@]}")"
}

# --- Gate resolution --------------------------------------------------------

rm -f "$BOXA_SSH_CONF"
assert_eq "missing config defaults off" "off" "$(resolve_gate /work/app)"
assert_eq "missing config source is default" "default" "$_BOXA_SSH_SOURCE"

seed_conf "agent = on"
assert_eq "global on" "on" "$(resolve_gate /work/app)"
_boxa::resolve_ssh_gate /work/app
assert_eq "global source is reported" "global" "$_BOXA_SSH_SOURCE"

seed_conf "agent=on" "[/work/app]" "agent = off"
assert_eq "project off overrides global on" "off" "$(resolve_gate /work/app)"
_boxa::resolve_ssh_gate /work/app
assert_eq "project source is reported" "project" "$_BOXA_SSH_SOURCE"
assert_eq "other project keeps global on" "on" "$(resolve_gate /work/other)"

seed_conf "agent=off" "[/work/app]" "agent=on"
assert_eq "project on overrides global off" "on" "$(resolve_gate /work/app)"

seed_conf "agent=on" "[relative/path]" "agent=off"
assert_eq "invalid section is ignored" "on" "$(resolve_gate /work/app)"

seed_conf "agent=on" "[/work/app]" "agent=maybe"
assert_eq "invalid project value does not override global" "on" \
    "$(resolve_gate /work/app)"

marker="$_TMPROOT/should-not-exist"
seed_conf "agent=\$(touch $marker)"
resolve_gate /work/app >/dev/null
assert_eq "config is never sourced" "absent" \
    "$([ -e "$marker" ] && printf present || printf absent)"

status_output="$(_boxa::ssh_status /work/app)"
assert_contains "status includes effective state" "SSH agent forwarding: off" \
    "$status_output"
assert_contains "status includes source" "Source: default (off)" "$status_output"
assert_contains "status includes config path" "Config: $BOXA_SSH_CONF" "$status_output"

# --- Structure-preserving config writer -----------------------------------

expected_conf="$_TMPROOT/expected.conf"
printf '%s' $'# global\nagent = off # replace\nunknown = untouched\n[/work/app]\nagent=off\nkeep = bytes' \
    > "$BOXA_SSH_CONF"
printf '%s' $'# global\nunknown = untouched\nagent = on\n[/work/app]\nagent=off\nkeep = bytes' \
    > "$expected_conf"
_boxa::write_ssh_conf global '' on
assert_file_eq "global writer preserves foreign bytes and final-newline state" \
    "$expected_conf" "$BOXA_SSH_CONF"
_boxa::write_ssh_conf global '' on
assert_file_eq "repeated global write is idempotent" "$expected_conf" "$BOXA_SSH_CONF"

printf '%s\n' '# keep global' 'agent = on' '[/work/app]' 'agent = off' \
    'foreign = preserve' '[/work/other]' 'agent = off' > "$BOXA_SSH_CONF"
printf '%s\n' '# keep global' 'agent = on' '[/work/app]' \
    'foreign = preserve' 'agent = on' '[/work/other]' 'agent = off' > "$expected_conf"
_boxa::write_ssh_conf project /work/app on
assert_file_eq "project writer replaces only target key and preserves foreign bytes" \
    "$expected_conf" "$BOXA_SSH_CONF"
_boxa::write_ssh_conf project /work/app on
assert_file_eq "repeated project write does not duplicate section or key" \
    "$expected_conf" "$BOXA_SSH_CONF"

printf '%s\n' '# keep' '[/work/other]' 'agent = on' > "$BOXA_SSH_CONF"
printf '%s\n' '# keep' '[/work/other]' 'agent = on' '[/work/new]' 'agent = off' \
    > "$expected_conf"
_boxa::write_ssh_conf project /work/new off
assert_file_eq "project writer appends one missing section" \
    "$expected_conf" "$BOXA_SSH_CONF"

printf '%s\n' '[/work/app]' 'agent = on' 'agent = off' 'keep = yes' \
    > "$BOXA_SSH_CONF"
printf '%s\n' '[/work/app]' 'keep = yes' 'agent = on' > "$expected_conf"
_boxa::write_ssh_conf project /work/app on
assert_file_eq "writer collapses duplicate target keys" "$expected_conf" "$BOXA_SSH_CONF"

cp "$BOXA_SSH_CONF" "$expected_conf"
if _boxa::write_ssh_conf project '/work/C#' on 2>/dev/null; then
    printf 'FAIL  writer rejects an unrepresentable project path\n'
    fail_count=$((fail_count + 1))
else
    printf 'PASS  writer rejects an unrepresentable project path\n'
fi
assert_file_eq "rejected writer leaves config byte-identical" \
    "$expected_conf" "$BOXA_SSH_CONF"

# --- Conditional Docker arguments and startup state ------------------------

export BOXA_TEST_SSH_ADD_RC=0
export BOXA_TEST_SSH_ADD_OUTPUT="256 SHA256:first work@example (ED25519)
4096 SHA256:second deploy key (RSA)"

rm -f "$BOXA_SSH_CONF"
run_forwarding /work/app "$agent_socket"
assert_not_contains "default off omits socket mount" "/tmp/ssh-agent.sock" \
    "$DOCKER_ARGS_TEXT"
assert_not_contains "default off omits SSH_AUTH_SOCK" "SSH_AUTH_SOCK=" \
    "$DOCKER_ARGS_TEXT"
assert_eq "default off startup state" "SSH: not forwarded (enable: boxa ssh on)" \
    "$SSH_STATUS"

seed_conf "agent=on"
run_forwarding /work/app "$agent_socket"
assert_contains "global on mounts socket" \
    "$agent_socket:/tmp/ssh-agent.sock" "$DOCKER_ARGS_TEXT"
assert_contains "global on sets container socket env" \
    "SSH_AUTH_SOCK=/tmp/ssh-agent.sock" "$DOCKER_ARGS_TEXT"
assert_eq "key comments appear in forwarded state" \
    "SSH: forwarded (keys: work@example, deploy key)" "$SSH_STATUS"
assert_eq "live keyed agent has no warning" "" "$SSH_WARNING"

seed_conf "agent=on" "[/work/app]" "agent=off"
run_forwarding /work/app "$agent_socket"
assert_not_contains "project off omits mount" "/tmp/ssh-agent.sock" \
    "$DOCKER_ARGS_TEXT"

seed_conf "agent=off" "[/work/app]" "agent=on"
export BOXA_TEST_SSH_ADD_RC=1
export BOXA_TEST_SSH_ADD_OUTPUT="The agent has no identities."
run_forwarding /work/app "$agent_socket"
assert_contains "project on mounts live empty agent" "/tmp/ssh-agent.sock" \
    "$DOCKER_ARGS_TEXT"
assert_eq "empty agent startup hint" \
    "SSH: forwarding on, but agent has no keys — run 'boxa ssh add'" \
    "$SSH_STATUS"
assert_eq "live empty agent has no unavailable warning" "" "$SSH_WARNING"

export BOXA_TEST_SSH_ADD_RC=2
run_forwarding /work/app "$_TMPROOT/missing.sock"
assert_not_contains "missing agent omits mount" "/tmp/ssh-agent.sock" \
    "$DOCKER_ARGS_TEXT"
assert_eq "missing agent keeps no-keys startup hint" \
    "SSH: forwarding on, but agent has no keys — run 'boxa ssh add'" \
    "$SSH_STATUS"
assert_contains "unavailable warning appears only with gate on" \
    "WARNING: SSH agent not available" "$SSH_WARNING"

# --- Scope guards -----------------------------------------------------------

docker_text="$(cat "$BOXA_DIR/docker-run.sh")"
# The following needles intentionally match literal shell source text.
# shellcheck disable=SC2016
assert_not_contains "container creation no longer starts ssh-agent" \
    'eval "$(ssh-agent -s)"' "$docker_text"
assert_not_contains "container creation no longer revives keychain" \
    'keychain' "$docker_text"
assert_not_contains "container creation never auto-loads default keys" \
    'ssh-add 2>/dev/null' "$docker_text"
# shellcheck disable=SC2016
assert_contains "Boxa SSH config mount remains" \
    '$BOXA_SSH_CONFIG:/home/node/.ssh/config:ro' "$docker_text"
# shellcheck disable=SC2016
assert_contains "full host SSH config flag mount remains" \
    '$HOME/.ssh/config:/home/node/.ssh/config:ro' "$docker_text"
assert_contains "CLI warns running Projects about required restart" \
    "takes effect after boxa stop && boxa" "$docker_text"

if [ "$fail_count" -gt 0 ]; then
    printf '\n%d test(s) failed.\n' "$fail_count"
    exit 1
fi

printf '\nAll SSH tests passed.\n'
