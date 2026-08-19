#!/bin/bash
# Plain-bash assertions for the SSH gate and docker-run forwarding block.
# Usage: bash tests/ssh.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOXA_DIR="$SCRIPT_DIR/.."
# shellcheck source-path=SCRIPTDIR source=../lib/resources.sh disable=SC1091
source "$BOXA_DIR/lib/resources.sh"
# shellcheck source-path=SCRIPTDIR source=../lib/picker.sh disable=SC1091
source "$BOXA_DIR/lib/picker.sh"
# shellcheck source-path=SCRIPTDIR source=../lib/ssh.sh disable=SC1091
source "$BOXA_DIR/lib/ssh.sh"
_BOXA_TEST_SSH_ENSURE_AGENT_DEF="$(declare -f _boxa::ssh_ensure_agent)"

_TMPROOT="$(mktemp -d)"
export BOXA_SSH_CONF="$_TMPROOT/ssh.conf"
export BOXA_SSH_AGENT_ENV="$_TMPROOT/ssh-agent.env"
export BOXA_KEYCHAIN_ENV="$_TMPROOT/missing-keychain-env"
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
    local input_state=unused mode=interactive
    if [ "${1:-}" = -l ]; then
        printf '%s\n' "${BOXA_TEST_SSH_ADD_OUTPUT:-}"
        return "${BOXA_TEST_SSH_ADD_RC:-1}"
    fi
    if [ "${SSH_ASKPASS_REQUIRE:-}" = force ]; then
        mode=noninteractive
        if IFS= read -r _ssh_add_input; then
            input_state=open
        else
            input_state=closed
        fi
        printf '%s:%s:%s\n' "$mode" "$input_state" "${2:-}" \
            >> "${BOXA_TEST_SSH_ADD_LOG:?}"
        return "${BOXA_TEST_SSH_ADD_NONINTERACTIVE_RC:-1}"
    fi
    printf '%s:%s:%s\n' "$mode" "$input_state" "${2:-}" \
        >> "${BOXA_TEST_SSH_ADD_LOG:?}"
    return "${BOXA_TEST_SSH_ADD_INTERACTIVE_RC:-0}"
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

seed_conf "agent=off" "[/work/app" "agent=on" "[/work/app]" "agent=off"
assert_eq "malformed section quarantines keys until a valid header" "off" \
    "$(resolve_gate /work/other)"

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

# --- Persisted agent fallback -----------------------------------------------

printf '%s\n' \
    "SSH_AUTH_SOCK=$agent_socket; export SSH_AUTH_SOCK;" \
    "SSH_AGENT_PID=$agent_pid; export SSH_AGENT_PID;" > "$BOXA_SSH_AGENT_ENV"
chmod 600 "$BOXA_SSH_AGENT_ENV"
SSH_AUTH_SOCK="$_TMPROOT/missing.sock"
export BOXA_TEST_SSH_ADD_RC=1
_boxa::ssh_resolve_agent
assert_eq "persisted live agent is restored after a dead environment socket" \
    "$agent_socket" "$SSH_AUTH_SOCK"

printf '%s\n' \
    "SSH_AUTH_SOCK=$_TMPROOT/dead.sock; export SSH_AUTH_SOCK;" \
    'SSH_AGENT_PID=999999; export SSH_AGENT_PID;' > "$BOXA_SSH_AGENT_ENV"
SSH_AUTH_SOCK="$_TMPROOT/missing.sock"
export BOXA_TEST_SSH_ADD_RC=2
if _boxa::ssh_resolve_agent; then
    printf 'FAIL  persisted dead agent socket is ignored\n'
    fail_count=$((fail_count + 1))
else
    printf 'PASS  persisted dead agent socket is ignored\n'
fi
assert_eq "dead persisted socket is cleared" "" "${SSH_AUTH_SOCK:-}"

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

# --- Key discovery ----------------------------------------------------------

key_dir="$_TMPROOT/keys"
mkdir -p "$key_dir/subdir"
printf 'private bytes must remain unread by Boxa\n' > "$key_dir/id_work"
chmod 000 "$key_dir/id_work"
printf '%s\n' 'ssh-ed25519 AAAATEST work@example' > "$key_dir/id_work.pub"
printf 'another private key\n' > "$key_dir/custom.pem"
printf 'hidden private key\n' > "$key_dir/.hidden_key"
printf 'host config\n' > "$key_dir/config"
printf 'hosts\n' > "$key_dir/known_hosts.old"
printf 'authorized\n' > "$key_dir/authorized_keys2"
printf 'environment\n' > "$key_dir/environment"
printf 'rc\n' > "$key_dir/rc"
printf 'moduli\n' > "$key_dir/moduli"
mkfifo "$key_dir/control.fifo"
ln -s "$agent_socket" "$key_dir/agent.sock"

discovered="$(_boxa::ssh_discover_keys "$key_dir")"
assert_contains "discovery includes regular candidate" "$key_dir/id_work" "$discovered"
assert_contains "discovery includes extension-agnostic candidate" \
    "$key_dir/custom.pem" "$discovered"
assert_contains "discovery includes hidden candidate" "$key_dir/.hidden_key" "$discovered"
assert_not_contains "discovery excludes public companions" ".pub" "$discovered"
assert_not_contains "discovery excludes config" "$key_dir/config" "$discovered"
assert_not_contains "discovery excludes known_hosts variants" \
    "$key_dir/known_hosts.old" "$discovered"
assert_not_contains "discovery excludes authorized_keys variants" \
    "$key_dir/authorized_keys2" "$discovered"
assert_not_contains "discovery excludes directories" "$key_dir/subdir" "$discovered"
assert_not_contains "discovery excludes non-regular socket entries" \
    "$key_dir/agent.sock" "$discovered"
assert_not_contains "discovery excludes non-regular fifos" \
    "$key_dir/control.fifo" "$discovered"
assert_eq "public companion comment is available for picker label" \
    "work@example" "$(_boxa::ssh_public_comment "$key_dir/id_work")"

# --- ssh-add behavioral passphrase detection -------------------------------

export BOXA_TEST_SSH_ADD_LOG="$_TMPROOT/ssh-add.log"
: > "$BOXA_TEST_SSH_ADD_LOG"
export BOXA_TEST_SSH_ADD_NONINTERACTIVE_RC=0
warning="$(_boxa::ssh_add_key "$key_dir/id_work" 2>&1 <<< 'must-not-be-read')"
assert_eq "passphrase-less key gets only the non-interactive attempt" \
    "noninteractive:closed:$key_dir/id_work" \
    "$(cat "$BOXA_TEST_SSH_ADD_LOG")"
assert_contains "passphrase-less warning explains forwarded agent power" \
    "Any agent in any forwarded box can use it anywhere" "$warning"
assert_contains "passphrase-less warning recommends ssh-keygen -p" \
    "ssh-keygen -p" "$warning"

: > "$BOXA_TEST_SSH_ADD_LOG"
export BOXA_TEST_SSH_ADD_NONINTERACTIVE_RC=1
export BOXA_TEST_SSH_ADD_INTERACTIVE_RC=0
_boxa::ssh_add_key "$key_dir/id_work" <<< 'one-passphrase' >/dev/null
assert_eq "protected key gets one closed attempt and one interactive attempt" \
    $'noninteractive:closed:'"$key_dir/id_work"$'\ninteractive:unused:'"$key_dir/id_work" \
    "$(cat "$BOXA_TEST_SSH_ADD_LOG")"

# --- Consent/manual fallback and boxa ssh on handoff -----------------------

discovery_marker="$_TMPROOT/discovery-called"
_boxa::ssh_ensure_agent() { return 0; }
_boxa::ssh_confirm_discovery() { return 1; }
_boxa::ssh_discover_keys() { touch "$discovery_marker"; }
_boxa::ssh_read_manual_path() { printf '%s\n' "$key_dir/id_work"; }
export BOXA_PICKER_FZF=0
export BOXA_PICKER_TEST_CHOICE=a
export BOXA_TEST_SSH_ADD_NONINTERACTIVE_RC=0
: > "$BOXA_TEST_SSH_ADD_LOG"
# shellcheck disable=SC2218  # implementation is sourced above; a test stub follows
_boxa::ssh_add_keys >/dev/null 2>&1
assert_eq "declined consent never lists the SSH directory" "absent" \
    "$([ -e "$discovery_marker" ] && printf present || printf absent)"
assert_eq "declined consent still offers a manual path" \
    "noninteractive:closed:$key_dir/id_work" \
    "$(cat "$BOXA_TEST_SSH_ADD_LOG")"

ssh_picker_calls=0
_boxa::ssh_add_keys() { ssh_picker_calls=$((ssh_picker_calls + 1)); }
printf '%s\n' \
    "SSH_AUTH_SOCK=$agent_socket; export SSH_AUTH_SOCK;" \
    "SSH_AGENT_PID=$agent_pid; export SSH_AGENT_PID;" > "$BOXA_SSH_AGENT_ENV"
chmod 600 "$BOXA_SSH_AGENT_ENV"
SSH_AUTH_SOCK="$_TMPROOT/missing.sock"
BOXA_TEST_SSH_ADD_RC=0
_boxa::ssh_add_keys_if_agent_unready
assert_eq "boxa ssh on restores persisted keyed agent and skips picker" \
    "0" "$ssh_picker_calls"
BOXA_TEST_SSH_ADD_RC=1
_boxa::ssh_add_keys_if_agent_unready
assert_eq "boxa ssh on opens picker for an empty agent" "1" "$ssh_picker_calls"
BOXA_TEST_SSH_ADD_RC=2
_boxa::ssh_add_keys_if_agent_unready
assert_eq "boxa ssh on opens picker for a dead agent" "2" "$ssh_picker_calls"

# A plain agent started by the picker must survive as discoverable state for a
# later boxa process. These mocks keep the test deterministic and avoid a
# second real agent process.
eval "$_BOXA_TEST_SSH_ENSURE_AGENT_DEF"
keychain() { return 1; }
ssh-agent() {
    printf '%s\n' \
        "SSH_AUTH_SOCK=$agent_socket; export SSH_AUTH_SOCK;" \
        "SSH_AGENT_PID=$agent_pid; export SSH_AGENT_PID;" \
        "echo Agent pid $agent_pid;"
}
ssh-add() {
    [ "${1:-}" = -l ] || return 0
    [ "${SSH_AUTH_SOCK:-}" = "$agent_socket" ] && return 1
    return 2
}
rm -f "$BOXA_SSH_AGENT_ENV"
SSH_AUTH_SOCK="$_TMPROOT/missing.sock"
_boxa::ssh_ensure_agent >/dev/null 2>&1
assert_eq "picker persists newly started agent output" "present" \
    "$([ -s "$BOXA_SSH_AGENT_ENV" ] && printf present || printf absent)"
assert_eq "persisted agent env has mode 600" "600" \
    "$(stat -c '%a' "$BOXA_SSH_AGENT_ENV" 2>/dev/null || printf missing)"
SSH_AUTH_SOCK="$_TMPROOT/missing.sock"
_boxa::ssh_resolve_agent
assert_eq "later invocation restores picker-started agent" \
    "$agent_socket" "$SSH_AUTH_SOCK"

# --- Existing-container startup state --------------------------------------

BOXA_TEST_CONTAINER_MOUNTED=1
BOXA_TEST_CONTAINER_KEYS='256 SHA256:first work@example (ED25519)'
docker() {
    case "${1:-}:${2:-}" in
        inspect:-f)
            [ "$BOXA_TEST_CONTAINER_MOUNTED" = 1 ] \
                && printf '%s\n' /tmp/ssh-agent.sock
            ;;
        exec:-u)
            if [ -n "$BOXA_TEST_CONTAINER_KEYS" ]; then
                printf '%s\n' "$BOXA_TEST_CONTAINER_KEYS"
                return 0
            fi
            return 1
            ;;
        *) return 2 ;;
    esac
}
assert_eq "existing mounted container reports forwarded keys" \
    "SSH: forwarded (keys: work@example)" \
    "$(_boxa::existing_container_ssh_status boxa-app)"
BOXA_TEST_CONTAINER_KEYS=
assert_eq "existing mounted container reports an empty agent" \
    "SSH: forwarding on, but agent has no keys — run 'boxa ssh add'" \
    "$(_boxa::existing_container_ssh_status boxa-app)"
BOXA_TEST_CONTAINER_MOUNTED=0
seed_conf 'agent=on'
assert_eq "existing unmounted container reports reality despite current gate" \
    "SSH: not forwarded (enable: boxa ssh on)" \
    "$(_boxa::existing_container_ssh_status boxa-app)"

assert_eq "every existing-container attach prints SSH state" "5" \
    "$(sed -n '5925,6000p' "$BOXA_DIR/docker-run.sh" \
        | grep -c '_boxa::print_existing_container_ssh_status')"

# shellcheck disable=SC2016  # matching literal shell source
assert_contains "CLI exposes standalone boxa ssh add" \
    'if [ "$SSH_ACTION" = add ]' "$docker_text"
assert_contains "bash completion exposes ssh add" \
    'compgen -W "add on off"' "$(cat "$BOXA_DIR/completions/boxa.bash")"
assert_contains "zsh completion exposes ssh add" \
    "'add:Add keys to the host SSH agent'" "$(cat "$BOXA_DIR/completions/_boxa")"

if [ "$fail_count" -gt 0 ]; then
    printf '\n%d test(s) failed.\n' "$fail_count"
    exit 1
fi

printf '\nAll SSH tests passed.\n'
