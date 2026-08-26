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
# shellcheck source-path=SCRIPTDIR source=../lib/forge.sh disable=SC1091
source "$BOXA_DIR/lib/forge.sh"
_BOXA_TEST_SSH_ENSURE_AGENT_DEF="$(declare -f _boxa::ssh_ensure_agent)"
_BOXA_TEST_AGENT_IDENTITY_ENSURE_DEF="$(declare -f _boxa::ssh_ensure_agent_identity_agent)"
_BOXA_TEST_RESOLVE_FORGE_IDENTITY_DEF="$(declare -f _boxa::resolve_forge_identity)"

_TMPROOT="$(mktemp -d)"
export BOXA_SSH_CONF="$_TMPROOT/ssh.conf"
export BOXA_SSH_AGENT_ENV="$_TMPROOT/ssh-agent.env"
export BOXA_KEYCHAIN_ENV="$_TMPROOT/missing-keychain-env"
export BOXA_AGENT_IDENTITY_DIR="$_TMPROOT/agent-identity"
BOXA_TEST_AGENT_SOCKET_DIR="$_TMPROOT/agent-identity/ssh-agent"
BOXA_TEST_AGENT_SOCKET="$_TMPROOT/agent-identity/ssh-agent/agent.sock"
BOXA_TEST_AGENT_SSH_ENV="$_TMPROOT/agent-identity/ssh-agent.env"
export BOXA_SSH_AGENTS_DIR="$_TMPROOT/ssh-agents"
export BOXA_SSH_KEY_REGISTRY="$_TMPROOT/ssh-key-registry"
export BOXA_TEST_SSH_ADD_LOG="$_TMPROOT/ssh-add.log"
BOXA_TEST_FORGE_CONF="$_TMPROOT/forge.conf"
BOXA_TEST_FORGE_DIR="$_TMPROOT/forge"
forwarding_block="$_TMPROOT/forwarding.sh"
sed -n '/^# SSH agent forwarding:/,/^# Pass through API key/p' \
    "$BOXA_DIR/docker-run.sh" | sed '$d' > "$forwarding_block"
cleanup_block="$_TMPROOT/ssh-unassigned-cleanup.sh"
sed -n \
    '/^_boxa::ssh_clear_unassigned_project_registry_locked()/,/^_boxa::ssh_on_project_follow_up()/p' \
    "$BOXA_DIR/docker-run.sh" | sed '$d' > "$cleanup_block"
# shellcheck source=/dev/null
source "$cleanup_block"

agent_socket="$_TMPROOT/agent.sock"
agent_output="$(ssh-agent -a "$agent_socket" -s)"
agent_pid="$(printf '%s\n' "$agent_output" \
    | sed -n 's/^SSH_AGENT_PID=\([0-9][0-9]*\);.*/\1/p')"

cleanup() {
    local dedicated_pid='' env_file
    if [ -r "$BOXA_TEST_AGENT_SSH_ENV" ]; then
        dedicated_pid="$(sed -n 's/^SSH_AGENT_PID=\([0-9][0-9]*\);.*/\1/p' \
            "$BOXA_TEST_AGENT_SSH_ENV")"
    fi
    [ -z "$dedicated_pid" ] || kill "$dedicated_pid" 2>/dev/null || true
    while IFS= read -r env_file; do
        dedicated_pid="$(sed -n 's/^SSH_AGENT_PID=\([0-9][0-9]*\);.*/\1/p' \
            "$env_file")"
        [ -z "$dedicated_pid" ] || kill "$dedicated_pid" 2>/dev/null || true
    done < <(find "$BOXA_SSH_AGENTS_DIR" -name agent.env -type f 2>/dev/null)
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

# shellcheck disable=SC2317  # mock is called indirectly by sourced SSH helpers
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

_boxa::forge_apply_default_persona_to_project() { :; }
_boxa::resolve_forge_identity() {
    case "$1" in
        /work/named) _BOXA_FORGE_RESOLVED_IDENTITY_ID=named-persona ;;
        *) _BOXA_FORGE_RESOLVED_IDENTITY_ID=test-persona ;;
    esac
}

# --- Gate resolution --------------------------------------------------------

rm -f "$BOXA_SSH_CONF"
assert_eq "missing config defaults off" "off" "$(resolve_gate /work/app)"
assert_eq "missing config source is default" "default" "$_BOXA_SSH_SOURCE"

seed_conf "agent = on"
legacy_conf_checksum="$(cksum "$BOXA_SSH_CONF")"
assert_eq "legacy global on maps to binary on" "on" "$(resolve_gate /work/app)"
_boxa::resolve_ssh_gate /work/app
assert_eq "global source is reported" "global" "$_BOXA_SSH_SOURCE"
assert_eq "legacy global source is marked" 1 "$_BOXA_SSH_LEGACY"
assert_eq "resolving legacy config twice retains its source mode" user \
    "$_BOXA_SSH_LEGACY_MODE"
assert_eq "legacy reads preserve config bytes" "$legacy_conf_checksum" \
    "$(cksum "$BOXA_SSH_CONF")"
legacy_note="$_TMPROOT/legacy-note"
_BOXA_SSH_LEGACY_NOTE_SHOWN=
{
    _boxa::resolve_ssh_gate /work/app
    _boxa::resolve_ssh_gate /work/app
} 2> "$legacy_note"
assert_eq "legacy migration note is emitted once per process" 1 \
    "$(grep -c 'Legacy SSH gate values are mapped in memory' "$legacy_note")"

seed_conf "agent=user" "[/work/app]" "agent = off"
assert_eq "project off overrides global on" "off" "$(resolve_gate /work/app)"
_boxa::resolve_ssh_gate /work/app
assert_eq "project source is reported" "project" "$_BOXA_SSH_SOURCE"
assert_eq "legacy Project off is marked" 1 "$_BOXA_SSH_LEGACY"
assert_eq "other project keeps global on" "on" "$(resolve_gate /work/other)"

seed_conf "agent=on" "[/work/app]" "gate=off"
_boxa::resolve_ssh_gate /work/app
assert_eq "explicit Project gate is not marked legacy" "" "$_BOXA_SSH_LEGACY"

seed_conf "agent=on" "gate=off"
_boxa::resolve_ssh_gate /work/app
assert_eq "later explicit global gate clears the legacy marker" "" \
    "$_BOXA_SSH_LEGACY"

seed_conf "agent=off" "[/work/app]" "agent=agent"
assert_eq "legacy Project agent maps to on" "on" "$(resolve_gate /work/app)"
if _boxa::ssh_agent_usage_configured; then
    printf 'PASS  Project gate on counts as SSH usage\n'
else
    printf 'FAIL  Project gate on counts as SSH usage\n'
    fail_count=$((fail_count + 1))
fi

seed_conf "gate=off" "[/work/app]" "gate=off"
if _boxa::ssh_agent_usage_configured; then
    printf 'FAIL  off gates do not count as SSH usage\n'
    fail_count=$((fail_count + 1))
else
    printf 'PASS  off gates do not count as SSH usage\n'
fi

seed_conf "gate=on"
if _boxa::ssh_agent_usage_configured; then
    printf 'PASS  global on gate counts as SSH usage\n'
else
    printf 'FAIL  global on gate counts as SSH usage\n'
    fail_count=$((fail_count + 1))
fi

seed_conf "agent=user" "[relative/path]" "agent=off"
assert_eq "invalid section is ignored" "on" "$(resolve_gate /work/app)"

seed_conf "agent=off" "[/work/app" "agent=on" "[/work/app]" "agent=off"
assert_eq "malformed section quarantines keys until a valid header" "off" \
    "$(resolve_gate /work/other)"

seed_conf "gate=on" "[/work/app]" "gate=maybe"
assert_eq "invalid project value forces the complete SSH gate off" "off" \
    "$(resolve_gate /work/app)"
_boxa::resolve_ssh_gate /work/app
assert_eq "invalid SSH gate source is reported" "invalid" "$_BOXA_SSH_SOURCE"

seed_conf "agent=maybe"
assert_eq "invalid legacy value also fails closed" "off" \
    "$(resolve_gate /work/app)"
_boxa::resolve_ssh_gate /work/app
assert_eq "invalid legacy SSH gate source is reported" "invalid" \
    "$_BOXA_SSH_SOURCE"

seed_conf
for gate_state in off on; do
    _boxa::write_ssh_conf global '' "$gate_state"
    assert_eq "global config roundtrips $gate_state" "$gate_state" \
        "$(resolve_gate /work/app)"
done

marker="$_TMPROOT/should-not-exist"
seed_conf "agent=\$(touch $marker)"
resolve_gate /work/app >/dev/null
assert_eq "config is never sourced" "absent" \
    "$([ -e "$marker" ] && printf present || printf absent)"

seed_conf 'gate=maybe'
status_output="$(_boxa::ssh_status /work/app)"
assert_contains "status includes effective state" "SSH agent forwarding: off" \
    "$status_output"
assert_contains "status includes invalid source" "Source: invalid config (off)" \
    "$status_output"
assert_contains "status includes config path" "Config: $BOXA_SSH_CONF" "$status_output"

# --- Structure-preserving config writer -----------------------------------

expected_conf="$_TMPROOT/expected.conf"
printf '%s' $'# global\ngate = off # replace\nunknown = untouched\n[/work/app]\ngate=off\nkeep = bytes' \
    > "$BOXA_SSH_CONF"
printf '%s' $'# global\nunknown = untouched\ngate = on\n[/work/app]\ngate=off\nkeep = bytes' \
    > "$expected_conf"
_boxa::write_ssh_conf global '' on
assert_file_eq "global writer preserves foreign bytes and final-newline state" \
    "$expected_conf" "$BOXA_SSH_CONF"
_boxa::write_ssh_conf global '' on
assert_file_eq "repeated global write is idempotent" "$expected_conf" "$BOXA_SSH_CONF"

printf '%s\n' '# keep global' 'gate = on' '[/work/app]' 'gate = off' \
    'foreign = preserve' '[/work/other]' 'gate = off' > "$BOXA_SSH_CONF"
printf '%s\n' '# keep global' 'gate = on' '[/work/app]' \
    'foreign = preserve' 'gate = on' '[/work/other]' 'gate = off' > "$expected_conf"
_boxa::write_ssh_conf project /work/app on
assert_file_eq "project writer replaces only target key and preserves foreign bytes" \
    "$expected_conf" "$BOXA_SSH_CONF"
_boxa::write_ssh_conf project /work/app on
assert_file_eq "repeated project write does not duplicate section or key" \
    "$expected_conf" "$BOXA_SSH_CONF"

printf '%s\n' '# keep' '[/work/other]' 'gate = on' > "$BOXA_SSH_CONF"
printf '%s\n' '# keep' '[/work/other]' 'gate = on' '[/work/new]' 'gate = off' \
    > "$expected_conf"
_boxa::write_ssh_conf project /work/new off
assert_file_eq "project writer appends one missing section" \
    "$expected_conf" "$BOXA_SSH_CONF"

printf '%s\n' '[/work/app]' 'gate = on' 'gate = off' 'keep = yes' \
    > "$BOXA_SSH_CONF"
printf '%s\n' '[/work/app]' 'keep = yes' 'gate = on' > "$expected_conf"
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
assert_eq "default off startup state" \
    "SSH: gate off (enable: boxa ssh on)" \
    "$SSH_STATUS"

seed_conf "gate=on"
run_forwarding /work/app "$agent_socket"
app_socket_dir="$(_boxa::ssh_project_agent_socket_dir /work/app)"
assert_contains "gate on mounts the Project socket directory" \
    "$app_socket_dir:/tmp/boxa-agent" "$DOCKER_ARGS_TEXT"
assert_contains "gate on sets the Project socket environment" \
    "SSH_AUTH_SOCK=/tmp/boxa-agent/agent.sock" "$DOCKER_ARGS_TEXT"
assert_eq "startup reports key fingerprints" \
    "SSH: gate on; per-project ssh-agent running (persona 'test-persona' keys: SHA256:first, SHA256:second)" \
    "$SSH_STATUS"

reapply_project=/work/reapply-once
reapply_key="$_TMPROOT/reapply-key"
: > "$reapply_key"
_boxa::ssh_registry_record_key "$reapply_project" "$reapply_key"
: > "$BOXA_TEST_SSH_ADD_LOG"
seed_conf "gate=on"
run_forwarding "$reapply_project" ""
run_forwarding "$reapply_project" ""
assert_eq "live Project agent is populated only on its first creation" 1 \
    "$(grep -cFx "noninteractive:closed:$reapply_key" \
        "$BOXA_TEST_SSH_ADD_LOG")"

seed_conf "gate=on" "[/work/app]" "gate=off"
run_forwarding /work/app "$agent_socket"
assert_not_contains "project off omits mount" "/tmp/boxa-agent" \
    "$DOCKER_ARGS_TEXT"

seed_conf "gate=off" "[/work/app]" "gate=on"
export BOXA_TEST_SSH_ADD_RC=1
export BOXA_TEST_SSH_ADD_OUTPUT="The agent has no identities."
run_forwarding /work/app "$agent_socket"
assert_contains "Project mounts its live empty agent" "/tmp/boxa-agent" \
    "$DOCKER_ARGS_TEXT"
assert_eq "empty agent startup hint" \
    "SSH: gate on; per-project ssh-agent running (persona 'test-persona', no keys) — run 'boxa ssh add'" \
    "$SSH_STATUS"
assert_eq "live empty agent has no unavailable warning" "" "$SSH_WARNING"

_boxa::ssh_ensure_project_agent /work/other
other_socket="$SSH_AUTH_SOCK"
other_pid="$SSH_AGENT_PID"
assert_not_contains "two Projects never share a socket directory" \
    "$other_socket" "$app_socket_dir/agent.sock"
app_env="$(_boxa::ssh_project_agent_env_path /work/app)"
app_pid="$(sed -n 's/^SSH_AGENT_PID=\([0-9][0-9]*\);.*/\1/p' "$app_env")"
kill "$app_pid"
for _ in {1..100}; do
    kill -0 "$app_pid" 2>/dev/null || break
    sleep 0.01
done
_boxa::ssh_ensure_project_agent /work/app
assert_eq "restarting one Project agent leaves another alive" "alive" \
    "$(kill -0 "$other_pid" 2>/dev/null && printf alive || printf dead)"
assert_eq "restarting one Project agent keeps the other socket" "$other_socket" \
    "$(_boxa::ssh_resolve_project_agent /work/other && printf '%s' "$SSH_AUTH_SOCK")"

override_dir="$_TMPROOT/single-project-override/socket"
override_socket="$override_dir/custom.sock"
override_env="$_TMPROOT/single-project-override/custom.env"
assert_eq "single-Project socket-dir override is preserved" "$override_dir" \
    "$(BOXA_AGENT_SOCKET_DIR="$override_dir" \
        _boxa::ssh_project_agent_socket_dir /work/override)"
assert_eq "single-Project socket-path override is preserved" "$override_socket" \
    "$(BOXA_AGENT_SOCKET="$override_socket" \
        _boxa::ssh_project_agent_socket_path /work/override)"
assert_eq "single-Project env override is preserved" "$override_env" \
    "$(BOXA_AGENT_SSH_ENV="$override_env" \
        _boxa::ssh_project_agent_env_path /work/override)"

keychain_read_marker="$_TMPROOT/keychain-read"
export BOXA_KEYCHAIN_ENV="$_TMPROOT/keychain-env"
printf '%s\n' \
    "touch $keychain_read_marker" \
    "SSH_AUTH_SOCK=$agent_socket; export SSH_AUTH_SOCK;" \
    "SSH_AGENT_PID=$agent_pid; export SSH_AGENT_PID;" > "$BOXA_KEYCHAIN_ENV"
rm -f "$BOXA_SSH_AGENT_ENV"
seed_conf "gate=on"
run_forwarding /work/app ""
assert_eq "container creation does not read keychain state" "absent" \
    "$([ -e "$keychain_read_marker" ] && printf present || printf absent)"
assert_contains "Project agent ignores the unrelated keychain agent" \
    "/tmp/boxa-agent" "$DOCKER_ARGS_TEXT"
rm -f "$BOXA_KEYCHAIN_ENV"
export BOXA_KEYCHAIN_ENV="$_TMPROOT/missing-keychain-env"

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

# --- Agent key and dedicated agent -----------------------------------------

export BOXA_AGENT_SOCKET_DIR="$BOXA_TEST_AGENT_SOCKET_DIR"
export BOXA_AGENT_SOCKET="$BOXA_TEST_AGENT_SOCKET"
export BOXA_AGENT_SSH_ENV="$BOXA_TEST_AGENT_SSH_ENV"
eval "$_BOXA_TEST_AGENT_IDENTITY_ENSURE_DEF"
dedicated_result="$(
    unset -f ssh-add
    _boxa::ssh_generate_agent_key || exit 1
    key_path="$(_boxa::ssh_agent_key_path)"
    key_checksum="$(cksum "$key_path")"
    _boxa::ssh_generate_agent_key || exit 1
    [ "$key_checksum" = "$(cksum "$key_path")" ] \
        && printf 'key-idempotent\n'
    printf 'key-mode:%s\n' "$(stat -c '%a' "$key_path")"
    printf 'key-comment:%s\n' "$(awk '{ print $3 }' "$key_path.pub")"

    _boxa::ssh_ensure_agent_identity_agent || exit 1
    first_pid="$SSH_AGENT_PID"
    first_socket="$SSH_AUTH_SOCK"
    first_keys="$(ssh-add -l)" || exit 1
    printf 'first-key-count:%s\n' \
        "$(printf '%s\n' "$first_keys" | awk 'NF { count++ } END { print count + 0 }')"
    printf 'first-key-fingerprint:%s\n' "$(printf '%s\n' "$first_keys" | awk 'NR == 1 { print $2 }')"

    kill "$first_pid" || exit 1
    for _ in {1..100}; do
        kill -0 "$first_pid" 2>/dev/null || break
        sleep 0.01
    done
    _boxa::ssh_ensure_agent_identity_agent || exit 1
    second_keys="$(ssh-add -l)" || exit 1
    [ "$SSH_AGENT_PID" != "$first_pid" ] && printf 'agent-resurrected\n'
    [ "$SSH_AUTH_SOCK" = "$first_socket" ] && printf 'socket-path-stable\n'
    printf 'second-key-count:%s\n' \
        "$(printf '%s\n' "$second_keys" | awk 'NF { count++ } END { print count + 0 }')"
)"
_BOXA_TEST_FORWARDING_SSH_ADD_DEF="$(declare -f ssh-add)"
unset -f ssh-add
agent_fingerprint="$(_boxa::ssh_agent_key_fingerprint)"
assert_contains "Agent key generation is idempotent" "key-idempotent" \
    "$dedicated_result"
assert_contains "Agent key private file has mode 600" "key-mode:600" \
    "$dedicated_result"
assert_contains "Agent key has the installation hostname comment" \
    "key-comment:boxa-agent@$(hostname)" "$dedicated_result"
assert_contains "dedicated agent initially holds exactly one key" \
    "first-key-count:1" "$dedicated_result"
assert_contains "dedicated agent holds the Agent key fingerprint" \
    "first-key-fingerprint:$agent_fingerprint" "$dedicated_result"
assert_contains "killed dedicated agent is resurrected" "agent-resurrected" \
    "$dedicated_result"
assert_contains "resurrected agent reuses the fixed socket path" \
    "socket-path-stable" "$dedicated_result"
assert_contains "resurrected dedicated agent still holds exactly one key" \
    "second-key-count:1" "$dedicated_result"

adopted_key="$_TMPROOT/adopted-key"
ssh-keygen -q -t ed25519 -N '' -C adopted@test -f "$adopted_key"
adopted_checksum="$(cksum "$adopted_key")"
chmod 400 "$adopted_key"
_boxa::ssh_adopt_agent_key "$adopted_key"
assert_eq "adoption resolves the external key path" "$adopted_key" \
    "$(_boxa::ssh_agent_key_path)"
assert_eq "adoption pointer has mode 600" "600" \
    "$(stat -c '%a' "$(_boxa::ssh_agent_key_pointer_path)")"
assert_eq "adoption leaves private-key mode untouched" "400" \
    "$(stat -c '%a' "$adopted_key")"
assert_eq "adoption leaves private-key bytes untouched" "$adopted_checksum" \
    "$(cksum "$adopted_key")"

rollback_key="$_TMPROOT/rollback-key"
ssh-keygen -q -t ed25519 -N '' -C rollback@test -f "$rollback_key"
pointer_checksum="$(cksum "$(_boxa::ssh_agent_key_pointer_path)")"
adopted_fingerprint="$(ssh-keygen -lf "$adopted_key.pub" | awk '{ print $2 }')"
# shellcheck disable=SC2317  # failure seam is called by the adoption helper
mktemp() {
    return 1
}
if _boxa::ssh_adopt_agent_key "$rollback_key" 2>/dev/null; then
    printf 'FAIL  failed pointer persistence rejects adoption\n'
    fail_count=$((fail_count + 1))
else
    printf 'PASS  failed pointer persistence rejects adoption\n'
fi
unset -f mktemp
assert_eq "failed adoption leaves the pointer untouched" "$pointer_checksum" \
    "$(cksum "$(_boxa::ssh_agent_key_pointer_path)")"
assert_eq "failed adoption restores the previously adopted Agent key" \
    "$adopted_fingerprint" "$(ssh-add -l | awk 'NR == 1 { print $2 }')"

mismatched_key="$_TMPROOT/mismatched-key"
mismatched_other="$_TMPROOT/mismatched-other"
ssh-keygen -q -t ed25519 -N '' -C mismatched@test -f "$mismatched_key"
ssh-keygen -q -t ed25519 -N '' -C other@test -f "$mismatched_other"
cp "$mismatched_other.pub" "$mismatched_key.pub"
pointer_checksum="$(cksum "$(_boxa::ssh_agent_key_pointer_path)")"
if _boxa::ssh_adopt_agent_key "$mismatched_key" 2>/dev/null; then
    printf 'FAIL  adoption rejects mismatched private and public halves\n'
    fail_count=$((fail_count + 1))
else
    printf 'PASS  adoption rejects mismatched private and public halves\n'
fi
assert_eq "rejected mismatch leaves the adopted pointer untouched" \
    "$pointer_checksum" "$(cksum "$(_boxa::ssh_agent_key_pointer_path)")"

private_only_agent_key="$_TMPROOT/private-only-agent-key"
ssh-keygen -q -t ed25519 -N '' -C private-only@test \
    -f "$private_only_agent_key"
rm "$private_only_agent_key.pub"
_boxa::ssh_adopt_agent_key "$private_only_agent_key"
assert_eq "private-only Agent key adoption records its path" \
    "$private_only_agent_key" "$(_boxa::ssh_agent_key_path)"
assert_eq "private-only Agent key uses its path as stable identity" \
    "$private_only_agent_key" "$(_boxa::ssh_agent_key_fingerprint)"
assert_eq "private-only adopted Agent key remains available" available \
    "$(_boxa::ssh_agent_key_exists && printf available || printf missing)"
ssh_text="$(cat "$BOXA_DIR/lib/ssh.sh")"
# shellcheck disable=SC2016  # matching the literal private-key loading boundary
assert_not_contains "adoption never derives public material from the private key" \
    'ssh-keygen -y -f "$key_path"' "$ssh_text"
# shellcheck disable=SC2016  # matching the literal dedicated-agent load
assert_contains "adoption delegates private-key loading to ssh-add" \
    'ssh-add -- "$key_path"' "$ssh_text"
rm -f "$(_boxa::ssh_agent_key_pointer_path)"
assert_eq "removing adoption pointer restores generated Agent key" \
    "$BOXA_AGENT_IDENTITY_DIR/id_ed25519" "$(_boxa::ssh_agent_key_path)"

export BOXA_AGENT_KEY="$_TMPROOT/incomplete-agent-key"
printf 'existing public half\n' > "$BOXA_AGENT_KEY.pub"
if _boxa::ssh_generate_agent_key 2>/dev/null; then
    printf 'FAIL  generation refuses to overwrite an incomplete key pair\n'
    fail_count=$((fail_count + 1))
else
    printf 'PASS  generation refuses to overwrite an incomplete key pair\n'
fi
assert_eq "incomplete public key remains byte-identical" "existing public half" \
    "$(cat "$BOXA_AGENT_KEY.pub")"
unset BOXA_AGENT_KEY

# Two simultaneous generators must serialize the existence check and final
# creation. The first fake ssh-keygen pauses inside generation; without the
# lock, the second succeeds and records bytes that the first then overwrites.
race_dir="$_TMPROOT/generation-race"
race_bin="$_TMPROOT/generation-race-bin"
mkdir -p "$race_dir" "$race_bin"
race_marker="$_TMPROOT/generation-race.marker"
race_release="$_TMPROOT/generation-race.release"
race_harness="$_TMPROOT/generation-race.sh"
cat > "$race_bin/ssh-keygen" <<'EOF'
#!/bin/bash
target=
while [ "$#" -gt 0 ]; do
    if [ "$1" = -f ]; then target="$2"; shift 2; else shift; fi
done
if [ "${BOXA_TEST_PAUSE:-}" = 1 ]; then
    : > "$BOXA_TEST_MARKER"
    while [ ! -e "$BOXA_TEST_RELEASE" ]; do sleep 0.05; done
fi
printf '%s-private\n' "$BOXA_TEST_VALUE" > "$target"
printf '%s-public\n' "$BOXA_TEST_VALUE" > "$target.pub"
EOF
chmod 700 "$race_bin/ssh-keygen"
cat > "$race_harness" <<EOF
#!/bin/bash
set -euo pipefail
source "$BOXA_DIR/lib/resources.sh"
source "$BOXA_DIR/lib/ssh.sh"
if [ "\${BOXA_TEST_LOCK_PAUSE:-}" = 1 ]; then
    _boxa::ssh_generate_agent_key_locked() {
        : > "\$BOXA_TEST_MARKER"
        while [ ! -e "\$BOXA_TEST_RELEASE" ]; do sleep 0.05; done
    }
fi
_boxa::ssh_generate_agent_key
cksum "\$BOXA_AGENT_IDENTITY_DIR/id_ed25519" > "\$BOXA_TEST_RESULT"
EOF
chmod 700 "$race_harness"
BOXA_AGENT_IDENTITY_DIR="$race_dir" PATH="$race_bin:$PATH" \
    BOXA_TEST_PAUSE=1 BOXA_TEST_MARKER="$race_marker" \
    BOXA_TEST_RELEASE="$race_release" BOXA_TEST_VALUE=first \
    BOXA_TEST_RESULT="$_TMPROOT/first.result" "$race_harness" &
first_race_pid=$!
for _ in {1..100}; do [ -e "$race_marker" ] && break; sleep 0.05; done
BOXA_AGENT_IDENTITY_DIR="$race_dir" PATH="$race_bin:$PATH" \
    BOXA_TEST_VALUE=second BOXA_TEST_RESULT="$_TMPROOT/second.result" \
    "$race_harness" &
second_race_pid=$!
sleep 0.1
: > "$race_release"
wait "$first_race_pid"
wait "$second_race_pid"
assert_eq "concurrent generation never overwrites a completed caller's key" \
    "$(cat "$_TMPROOT/second.result")" \
    "$(cksum "$race_dir/id_ed25519")"

stale_race_dir="$_TMPROOT/generation-stale-lock"
mkdir -p "$stale_race_dir/.agent-key.lock"
printf '999999999\n' > "$stale_race_dir/.agent-key.lock/owner"
BOXA_AGENT_IDENTITY_DIR="$stale_race_dir" PATH="$race_bin:$PATH" \
    BOXA_TEST_VALUE=stale BOXA_TEST_RESULT="$_TMPROOT/stale.result" \
    "$race_harness"
assert_eq "generation reclaims a lock owned by a dead process" "stale-private" \
    "$(cat "$stale_race_dir/id_ed25519")"
assert_eq "reclaimed generation lock is removed after success" "absent" \
    "$([ -e "$stale_race_dir/.agent-key.lock" ] && printf present || printf absent)"

# A waiter may take over a missing-owner lock only while holding the claim.
# Pause the creator immediately after mkdir, let a second process take over,
# then release the creator and prove the callbacks remain serialized.
pid_lock_harness="$_TMPROOT/pid-lock-race.sh"
pid_lock_dir="$_TMPROOT/pid-lock-race.lock"
pid_lock_mkdir_marker="$_TMPROOT/pid-lock-mkdir.marker"
pid_lock_mkdir_release="$_TMPROOT/pid-lock-mkdir.release"
pid_lock_callback_marker="$_TMPROOT/pid-lock-callback.marker"
pid_lock_callback_release="$_TMPROOT/pid-lock-callback.release"
pid_lock_critical="$_TMPROOT/pid-lock-critical"
pid_lock_entries="$_TMPROOT/pid-lock-entries"
pid_lock_overlap="$_TMPROOT/pid-lock-overlap"
cat > "$pid_lock_harness" <<EOF
#!/bin/bash
set -euo pipefail
source "$BOXA_DIR/lib/resources.sh"
callback() {
    if ! mkdir "$pid_lock_critical" 2>/dev/null; then
        : > "$pid_lock_overlap"
        return 1
    fi
    printf '%s\n' "\$BOXA_TEST_VALUE" >> "$pid_lock_entries"
    if [ "\${BOXA_TEST_CALLBACK_PAUSE:-}" = 1 ]; then
        : > "$pid_lock_callback_marker"
        while [ ! -e "$pid_lock_callback_release" ]; do sleep 0.01; done
    fi
    rmdir "$pid_lock_critical"
}
_boxa::with_pid_lock "$pid_lock_dir" callback
EOF
chmod 700 "$pid_lock_harness"
BOXA_TEST_PID_LOCK_AFTER_MKDIR_MARKER="$pid_lock_mkdir_marker" \
    BOXA_TEST_PID_LOCK_AFTER_MKDIR_RELEASE="$pid_lock_mkdir_release" \
    BOXA_TEST_VALUE=creator "$pid_lock_harness" &
pid_lock_creator=$!
for _ in {1..100}; do
    [ -e "$pid_lock_mkdir_marker" ] && break
    sleep 0.01
done
BOXA_PID_LOCK_MISSING_OWNER_GRACE=0 BOXA_TEST_CALLBACK_PAUSE=1 \
    BOXA_TEST_VALUE=waiter "$pid_lock_harness" &
pid_lock_waiter=$!
for _ in {1..100}; do
    [ -e "$pid_lock_callback_marker" ] && break
    sleep 0.01
done
: > "$pid_lock_mkdir_release"
assert_eq "creator cannot enter while missing-owner takeover callback runs" \
    "waiter" "$(cat "$pid_lock_entries")"
assert_eq "missing-owner takeover has no overlapping callbacks" "absent" \
    "$([ -e "$pid_lock_overlap" ] && printf present || printf absent)"
: > "$pid_lock_callback_release"
wait "$pid_lock_waiter"
wait "$pid_lock_creator"
assert_eq "paused creator runs only after the takeover releases the lock" \
    $'waiter\ncreator' "$(cat "$pid_lock_entries")"
assert_eq "completed missing-owner race leaves no lock" "absent" \
    "$([ -e "$pid_lock_dir" ] && printf present || printf absent)"

rm -f "$pid_lock_mkdir_marker" "$pid_lock_mkdir_release" \
    "$pid_lock_callback_marker" "$pid_lock_callback_release" \
    "$pid_lock_entries" "$pid_lock_overlap"
mkdir -p "$pid_lock_dir"
printf '999999999\n' > "$pid_lock_dir/owner"
pid_lock_claim_marker="$_TMPROOT/pid-lock-claim.marker"
pid_lock_claim_release="$_TMPROOT/pid-lock-claim.release"
BOXA_TEST_PID_LOCK_BEFORE_CLAIM_MARKER="$pid_lock_claim_marker" \
    BOXA_TEST_PID_LOCK_BEFORE_CLAIM_RELEASE="$pid_lock_claim_release" \
    BOXA_TEST_VALUE=delayed-waiter "$pid_lock_harness" &
pid_lock_delayed_waiter=$!
for _ in {1..100}; do
    [ -e "$pid_lock_claim_marker" ] && break
    sleep 0.01
done
BOXA_TEST_CALLBACK_PAUSE=1 BOXA_TEST_VALUE=claim-winner \
    "$pid_lock_harness" &
pid_lock_claim_winner=$!
for _ in {1..100}; do
    [ -e "$pid_lock_callback_marker" ] && break
    sleep 0.01
done
: > "$pid_lock_claim_release"
assert_eq "delayed stale waiter cannot displace the claim winner" \
    "claim-winner" "$(cat "$pid_lock_entries")"
assert_eq "competing stale waiters have no overlapping callbacks" "absent" \
    "$([ -e "$pid_lock_overlap" ] && printf present || printf absent)"
: > "$pid_lock_callback_release"
wait "$pid_lock_claim_winner"
wait "$pid_lock_delayed_waiter"
assert_eq "competing stale waiters run sequentially" \
    $'claim-winner\ndelayed-waiter' "$(cat "$pid_lock_entries")"

rm -f "$pid_lock_callback_marker" "$pid_lock_callback_release" \
    "$pid_lock_entries" "$pid_lock_overlap"
mkdir -p "$pid_lock_dir"
printf '999999999\n' > "$pid_lock_dir/owner"
printf '999999998\n' > "$pid_lock_dir/claim"
pid_lock_stale_marker="$_TMPROOT/pid-lock-stale-rename.marker"
pid_lock_stale_release="$_TMPROOT/pid-lock-stale-rename.release"
BOXA_TEST_PID_LOCK_BEFORE_STALE_CLAIM_RENAME_MARKER="$pid_lock_stale_marker" \
    BOXA_TEST_PID_LOCK_BEFORE_STALE_CLAIM_RENAME_RELEASE="$pid_lock_stale_release" \
    BOXA_TEST_VALUE=delayed-rename "$pid_lock_harness" &
pid_lock_delayed_rename=$!
for _ in {1..100}; do
    [ -e "$pid_lock_stale_marker" ] && break
    sleep 0.01
done
BOXA_TEST_CALLBACK_PAUSE=1 BOXA_TEST_VALUE=rename-winner \
    "$pid_lock_harness" &
pid_lock_rename_winner=$!
for _ in {1..100}; do
    [ -e "$pid_lock_callback_marker" ] && break
    sleep 0.01
done
: > "$pid_lock_stale_release"
assert_eq "delayed stale rename cannot displace the takeover winner" \
    "rename-winner" "$(cat "$pid_lock_entries")"
assert_eq "rename-based stale takeover has no overlapping callbacks" "absent" \
    "$([ -e "$pid_lock_overlap" ] && printf present || printf absent)"
: > "$pid_lock_callback_release"
wait "$pid_lock_rename_winner"
wait "$pid_lock_delayed_rename"
assert_eq "rename-based stale contenders run sequentially" \
    $'rename-winner\ndelayed-rename' "$(cat "$pid_lock_entries")"

rm -f "$pid_lock_entries" "$pid_lock_callback_marker" \
    "$pid_lock_callback_release"
mkdir -p "$pid_lock_dir"
printf '999999999\n' > "$pid_lock_dir/owner"
printf '999999998\n' > "$pid_lock_dir/claim"
pid_lock_tombstone_marker="$_TMPROOT/pid-lock-tombstone.marker"
pid_lock_tombstone_release="$_TMPROOT/pid-lock-tombstone.release"
BOXA_TEST_PID_LOCK_AFTER_STALE_CLAIM_RENAME_MARKER="$pid_lock_tombstone_marker" \
    BOXA_TEST_PID_LOCK_AFTER_STALE_CLAIM_RENAME_RELEASE="$pid_lock_tombstone_release" \
    BOXA_TEST_VALUE=interrupted-tombstone "$pid_lock_harness" 2>/dev/null &
pid_lock_interrupted_tombstone=$!
for _ in {1..100}; do
    [ -e "$pid_lock_tombstone_marker" ] && break
    sleep 0.01
done
kill -KILL "$(cat "$pid_lock_tombstone_marker")"
wait "$pid_lock_interrupted_tombstone" 2>/dev/null || true
if BOXA_TEST_VALUE=tombstone-recovered "$pid_lock_harness"; then
    printf 'PASS  interrupted stale-rename tombstone is recovered\n'
else
    printf 'FAIL  interrupted stale-rename tombstone is recovered\n'
    fail_count=$((fail_count + 1))
fi
assert_eq "tombstone recovery reaches the callback" "tombstone-recovered" \
    "$(cat "$pid_lock_entries" 2>/dev/null || true)"
assert_eq "tombstone recovery leaves no lock" "absent" \
    "$([ -e "$pid_lock_dir" ] && printf present || printf absent)"

rm -f "$pid_lock_entries" "$pid_lock_callback_marker" \
    "$pid_lock_callback_release"
mkdir -p "$pid_lock_dir"
printf '999999999\n' > "$pid_lock_dir/owner"
pid_lock_after_claim_marker="$_TMPROOT/pid-lock-after-claim.marker"
pid_lock_after_claim_release="$_TMPROOT/pid-lock-after-claim.release"
BOXA_TEST_PID_LOCK_AFTER_CLAIM_MARKER="$pid_lock_after_claim_marker" \
    BOXA_TEST_PID_LOCK_AFTER_CLAIM_RELEASE="$pid_lock_after_claim_release" \
    BOXA_TEST_VALUE=interrupted-claim "$pid_lock_harness" 2>/dev/null &
pid_lock_interrupted_claim=$!
for _ in {1..100}; do
    [ -e "$pid_lock_after_claim_marker" ] && break
    sleep 0.01
done
assert_eq "published PID-lock claim is a regular file" "file" \
    "$([ -f "$pid_lock_dir/claim" ] && printf file || printf other)"
assert_eq "published PID-lock claim atomically contains its owner" \
    "$(cat "$pid_lock_after_claim_marker")" "$(cat "$pid_lock_dir/claim")"
kill -KILL "$(cat "$pid_lock_after_claim_marker")"
wait "$pid_lock_interrupted_claim" 2>/dev/null || true
if BOXA_TEST_VALUE=claim-recovered "$pid_lock_harness"; then
    printf 'PASS  orphaned claim is recovered after its owner dies\n'
else
    printf 'FAIL  orphaned claim is recovered after its owner dies\n'
    fail_count=$((fail_count + 1))
fi
assert_eq "orphaned-claim recovery reaches the callback" "claim-recovered" \
    "$(cat "$pid_lock_entries" 2>/dev/null || true)"
assert_eq "orphaned-claim recovery leaves no lock" "absent" \
    "$([ -e "$pid_lock_dir" ] && printf present || printf absent)"

signal_race_dir="$_TMPROOT/generation-signal-lock"
signal_marker="$_TMPROOT/generation-signal.marker"
signal_release="$_TMPROOT/generation-signal.release"
BOXA_AGENT_IDENTITY_DIR="$signal_race_dir" PATH="$race_bin:$PATH" \
    BOXA_TEST_LOCK_PAUSE=1 BOXA_TEST_MARKER="$signal_marker" \
    BOXA_TEST_RELEASE="$signal_release" BOXA_TEST_VALUE=signal \
    BOXA_TEST_RESULT="$_TMPROOT/signal.result" "$race_harness" &
signal_race_pid=$!
for _ in {1..100}; do [ -e "$signal_marker" ] && break; sleep 0.05; done
signal_lock_owner="$(cat "$signal_race_dir/.agent-key.lock/owner")"
kill -TERM "$signal_lock_owner"
signal_race_status=0
wait "$signal_race_pid" || signal_race_status=$?
assert_eq "interrupted generation exits for the terminating signal" "143" \
    "$signal_race_status"
assert_eq "interrupted generation removes its lock" "absent" \
    "$([ -e "$signal_race_dir/.agent-key.lock" ] && printf present || printf absent)"
BOXA_AGENT_IDENTITY_DIR="$signal_race_dir" PATH="$race_bin:$PATH" \
    BOXA_TEST_VALUE=recovered BOXA_TEST_RESULT="$_TMPROOT/recovered.result" \
    "$race_harness"
assert_eq "generation succeeds after interrupted-owner cleanup" \
    "recovered-private" "$(cat "$signal_race_dir/id_ed25519")"
unset BOXA_AGENT_SOCKET_DIR BOXA_AGENT_SOCKET BOXA_AGENT_SSH_ENV
eval "$_BOXA_TEST_FORWARDING_SSH_ADD_DEF"

agent_key_checksum="$(cksum "$(_boxa::ssh_agent_key_path)")"
legacy_agent_result="$(
    unset -f ssh-add
    seed_conf 'agent=agent'
    _boxa::resolve_ssh_gate /work/legacy-agent || exit 1
    [ "$_BOXA_SSH_LEGACY_MODE" = agent ] || exit 1
    _boxa::ssh_apply_legacy_keys /work/legacy-agent agent || exit 1
    ssh-add -l | awk 'NR == 1 { print $2 }'
)"
assert_eq "legacy agent mode seeds the Project agent with the Agent key" \
    "$agent_fingerprint" "$legacy_agent_result"
assert_eq "legacy migration preserves global Agent key material" \
    "$agent_key_checksum" "$(cksum "$(_boxa::ssh_agent_key_path)")"

seed_conf 'gate=on'
export BOXA_TEST_SSH_ADD_RC=0
export BOXA_TEST_SSH_ADD_OUTPUT="256 $agent_fingerprint boxa-agent@test (ED25519)"
_boxa::ssh_ensure_project_agent /work/app
status_output="$(_boxa::ssh_status /work/app)"
assert_contains "status reports Project agent liveness" \
    "Per-project ssh-agent: running (persona 'test-persona' keys:" \
    "$status_output"
assert_contains "status renders key fingerprints" \
    "SHA256:" "$status_output"

# --- Binary CLI switching and legacy-user migration through a real PTY -----

cli_bin="$_TMPROOT/cli-bin"
cli_home="$_TMPROOT/cli-home"
cli_project="$_TMPROOT/cli-project"
cli_key="$_TMPROOT/cli-key"
cli_ssh_add_log="$_TMPROOT/cli-ssh-add.log"
mkdir -p "$cli_bin" "$cli_home" "$cli_project"
ssh-keygen -q -t ed25519 -N '' -C cli-key -f "$cli_key"
: > "$cli_ssh_add_log"

# The generated fakes expand these variables only in the CLI subprocess.
# shellcheck disable=SC2016
printf '%s\n' \
    '#!/bin/bash' \
    'case "${1:-}" in' \
    '    ps)' \
    '        [ "${BOXA_TEST_CLI_CONTAINER_RUNNING:-0}" = 1 ] || exit 0' \
    '        case "$*" in' \
    '            *"{{.Names}}"*) printf "%s\n" boxa-cli-project ;;' \
    '            *"{{.ID}}"*) printf "%s\n" cli-container-id ;;' \
    '        esac' \
    '        ;;' \
    '    inspect)' \
    '        printf "BOXA_PROJECT_HOST_PATH=%s\n" "$BOXA_TEST_CLI_PROJECT"' \
    '        ;;' \
    'esac' \
    > "$cli_bin/docker"
# shellcheck disable=SC2016
printf '%s\n' \
    '#!/bin/bash' \
    'if [ "${BOXA_TEST_CLI_REAL_SSH_ADD:-0}" = 1 ]; then' \
    '    exec /usr/bin/ssh-add "$@"' \
    'fi' \
    'printf "%s\n" "$*" >> "$BOXA_TEST_CLI_SSH_ADD_LOG"' \
    '[ "${1:-}" != -l ]' \
    > "$cli_bin/ssh-add"
chmod +x "$cli_bin/docker" "$cli_bin/ssh-add"

export BOXA_TEST_CLI_CONTAINER_RUNNING=1
export BOXA_TEST_CLI_PROJECT="$cli_project"
export BOXA_TEST_CLI_SSH_ADD_LOG="$cli_ssh_add_log"
cli_env="HOME='$cli_home' PATH='$cli_bin:$PATH' SSH_AUTH_SOCK='$agent_socket' BOXA_PICKER_FZF=0"

rm -f "$BOXA_SSH_CONF"
gate_state=off
cli_transcript="$_TMPROOT/project-$gate_state.transcript"
script -q -e -E never \
    -c "$cli_env bash '$BOXA_DIR/docker-run.sh' ssh '$gate_state' '$cli_project'" \
    "$cli_transcript" </dev/null >/dev/null
assert_eq "project CLI switches to $gate_state" "$gate_state" \
    "$(resolve_gate "$cli_project")"
assert_contains "project $gate_state warns for a running Container" \
    "boxa stop && boxa" "$(cat "$cli_transcript")"

cli_candidate_dir="$cli_home/.config/boxa/forge/identities"
cli_forge_conf="$cli_home/.config/boxa/forge.conf"
mkdir -p "$cli_candidate_dir"
printf 'forge = on\n' > "$cli_forge_conf"
printf '%s\n' \
    'version=2' \
    'name=candidate' \
    'kind=mine' \
    'github_created_at=1' \
    'github_username=candidate-user' \
    'github_token=candidate-token' \
    'gitlab_created_at=' \
    'gitlab_host=' \
    'gitlab_username=' \
    'gitlab_token=' \
    > "$cli_candidate_dir/candidate"
chmod 600 "$cli_candidate_dir/candidate"
_boxa::ssh_registry_record_key "$cli_project" "$cli_key"
cli_other_registry_project="$_TMPROOT/cli-other-registry-project"
mkdir -p "$cli_other_registry_project"
_boxa::ssh_registry_record_key "$cli_other_registry_project" "$cli_key"
(
    unset -f ssh-add
    _boxa::ssh_ensure_project_agent "$cli_project" || exit 1
    _boxa::ssh_reapply_registry_keys "$cli_project" >/dev/null || exit 1
)
project_on_transcript="$_TMPROOT/project-on.transcript"
printf '1\nq\n' | script -q -e -E never \
    -c "BOXA_TEST_CLI_REAL_SSH_ADD=1 $cli_env bash '$BOXA_DIR/docker-run.sh' ssh on '$cli_project'" \
    "$project_on_transcript" >/dev/null
assert_eq "project CLI switches to on" on "$(resolve_gate "$cli_project")"
assert_contains "project on with legacy registry keys but no persona opens assignment" \
    'Question: Which persona should be assigned?' \
    "$(cat "$project_on_transcript")"
assert_contains "project on preselects its target in assignment" \
    'a) cli-project' "$(cat "$project_on_transcript")"
assert_contains "cancelled assignment leaves the gate on with guidance" \
    'Gate is on, but no persona is assigned' "$(cat "$project_on_transcript")"
_BOXA_SSH_REGISTRY_KEYS=()
_boxa::ssh_registry_load_project "$cli_project"
assert_eq "cancelled assignment clears the Project's legacy registry keys" \
    0 "${#_BOXA_SSH_REGISTRY_KEYS[@]}"
_BOXA_SSH_REGISTRY_KEYS=()
_boxa::ssh_registry_load_project "$cli_other_registry_project"
assert_eq "cancelled assignment preserves other Projects' registry keys" \
    "$cli_key" "${_BOXA_SSH_REGISTRY_KEYS[*]}"
cancelled_agent_state="$(
    unset -f ssh-add
    _boxa::ssh_resolve_project_agent "$cli_project" || exit 1
    _boxa::ssh_agent_state
)"
assert_eq "cancelled assignment empties the running Project agent" empty \
    "$cancelled_agent_state"
assert_not_contains "project on never opens the legacy key picker" \
    'Look into ~/.ssh and offer keys to add?' \
    "$(cat "$project_on_transcript")"
assert_contains "project on warns for a running Container" \
    "boxa stop && boxa" "$(cat "$project_on_transcript")"

rm -f "$BOXA_SSH_CONF"
for gate_state in off on; do
    cli_transcript="$_TMPROOT/global-$gate_state.transcript"
    script -q -e -E never \
        -c "$cli_env bash '$BOXA_DIR/docker-run.sh' ssh '$gate_state' --global" \
        "$cli_transcript" </dev/null >/dev/null
    assert_eq "global CLI switches to $gate_state" "$gate_state" \
        "$(resolve_gate "$cli_project")"
    assert_contains "global $gate_state warns for an affected running Container" \
        "boxa stop && boxa" "$(cat "$cli_transcript")"
done

legacy_user_transcript="$_TMPROOT/legacy-user.transcript"
_boxa::ssh_registry_remove_key "$cli_project" "$cli_key"
printf 'agent = user\n' > "$BOXA_SSH_CONF"
printf 'n\na\n%s\n' "$cli_key" | script -q -e -E never \
    -c "cd '$cli_project' && $cli_env bash '$BOXA_DIR/docker-run.sh' ssh" \
    "$legacy_user_transcript" >/dev/null
assert_eq "legacy user config migrates to on" on "$(resolve_gate "$cli_project")"
assert_contains "legacy user migration prints a visible note" \
    'Legacy user mode now uses a per-project ssh-agent' \
    "$(cat "$legacy_user_transcript")"
assert_contains "legacy user migration uses the real consent prompt" \
    'Look into ~/.ssh and offer keys to add? [y/N]' \
    "$(cat "$legacy_user_transcript")"

seed_conf "gate=on" "[$cli_project]" "gate=on"
cli_persona_dir="$cli_home/.config/boxa/forge/identities"
mkdir -p "$cli_persona_dir"
printf '%s\n' \
    'version=2' \
    'name=cli-persona' \
    'kind=mine' \
    'github_created_at=1' \
    'github_username=cli-user' \
    'github_token=cli-token' \
    'gitlab_created_at=' \
    'gitlab_host=' \
    'gitlab_username=' \
    'gitlab_token=' \
    > "$cli_persona_dir/cli-persona"
chmod 600 "$cli_persona_dir/cli-persona"
printf 'forge = on\nidentity = cli-persona\n' > "$cli_forge_conf"
_boxa::ssh_registry_remove_key "$cli_project" "$cli_key"

keyless_transcript="$_TMPROOT/project-keyless.transcript"
script -q -e -E never \
    -c "$cli_env bash '$BOXA_DIR/docker-run.sh' ssh on '$cli_project'" \
    "$keyless_transcript" </dev/null >/dev/null
assert_contains "project on names its keyless persona" \
    "Gate is on, but persona 'cli-persona' has no attached SSH keys" \
    "$(cat "$keyless_transcript")"
assert_not_contains "keyless persona never opens the legacy key picker" \
    'Look into ~/.ssh and offer keys to add?' "$(cat "$keyless_transcript")"

BOXA_FORGE_CONF="$cli_forge_conf" \
    _boxa::write_forge_conf project "$cli_project" off
_boxa::write_ssh_conf project "$cli_project" off
_boxa::ssh_registry_record_key "$cli_project" "$cli_key"
(
    unset -f ssh-add
    _boxa::ssh_resolve_project_agent "$cli_project" || exit 1
    ssh-add -D >/dev/null
)
forge_off_ssh_before="$(cat "$BOXA_SSH_CONF")"
forge_off_on_transcript="$_TMPROOT/project-forge-off-on.transcript"
forge_off_on_rc=0
script -q -e -E never \
    -c "BOXA_TEST_CLI_REAL_SSH_ADD=1 $cli_env bash '$BOXA_DIR/docker-run.sh' ssh on '$cli_project'" \
    "$forge_off_on_transcript" </dev/null >/dev/null || forge_off_on_rc=$?
assert_eq "ssh on under forge off exits non-zero" 1 "$forge_off_on_rc"
assert_eq "ssh on under forge off preserves ssh.conf" \
    "$forge_off_ssh_before" "$(cat "$BOXA_SSH_CONF")"
assert_eq "ssh on under forge off leaves the Project gate off" off \
    "$(resolve_gate "$cli_project")"
_BOXA_SSH_REGISTRY_KEYS=()
_boxa::ssh_registry_load_project "$cli_project"
assert_eq "ssh on under forge off preserves the registered persona key" \
    "$cli_key" "${_BOXA_SSH_REGISTRY_KEYS[*]}"
forge_off_agent_state="$(
    unset -f ssh-add
    _boxa::ssh_resolve_project_agent "$cli_project" || exit 1
    _boxa::ssh_agent_state
)"
assert_eq "ssh on under forge off does not refill the Project agent" empty \
    "$forge_off_agent_state"
assert_contains "ssh on under forge off points to forge on" \
    "Forge access is off for $cli_project. Run 'boxa forge on $cli_project' before enabling SSH forwarding." \
    "$(cat "$forge_off_on_transcript")"

cli_other_project="$_TMPROOT/cli-other-project"
mkdir -p "$cli_other_project"
printf '\n[%s]\ngate = on\n' "$cli_other_project" >> "$BOXA_SSH_CONF"
pick_off_transcript="$_TMPROOT/project-pick-off.transcript"
printf '1,2\n' | script -q -e -E never \
    -c "$cli_env bash '$BOXA_DIR/docker-run.sh' ssh off --pick" \
    "$pick_off_transcript" >/dev/null
assert_eq "ssh off --pick changes the first selected Project" off \
    "$(resolve_gate "$cli_project")"
assert_eq "ssh off --pick changes the second selected Project" off \
    "$(resolve_gate "$cli_other_project")"
assert_contains "ssh off --pick prints the first Project result" \
    "SSH agent forwarding set to off for $cli_project" \
    "$(cat "$pick_off_transcript")"
assert_contains "ssh off --pick prints the second Project result" \
    "SSH agent forwarding set to off for $cli_other_project" \
    "$(cat "$pick_off_transcript")"

pick_on_transcript="$_TMPROOT/project-pick-on.transcript"
pick_on_rc=0
printf '1,2\n' | script -q -e -E never \
    -c "$cli_env bash '$BOXA_DIR/docker-run.sh' ssh on --pick" \
    "$pick_on_transcript" >/dev/null || pick_on_rc=$?
assert_eq "ssh on --pick reports skipped forge-off Projects" 1 "$pick_on_rc"
assert_eq "ssh on --pick skips the forge-off Project" off \
    "$(resolve_gate "$cli_project")"
assert_eq "ssh on --pick changes the second selected Project" on \
    "$(resolve_gate "$cli_other_project")"
assert_contains "ssh on --pick explains the skipped forge-off Project" \
    "Forge access is off for $cli_project. Run 'boxa forge on $cli_project' before enabling SSH forwarding." \
    "$(cat "$pick_on_transcript")"
assert_contains "ssh on --pick prints keyless persona guidance" \
    "Gate is on, but persona 'cli-persona' has no attached SSH keys" \
    "$(cat "$pick_on_transcript")"

for usage_args in "--pick $cli_project" "--pick --global"; do
    usage_transcript="$_TMPROOT/project-usage-${usage_args//[^a-z]/}.transcript"
    usage_rc=0
    script -q -e -E never \
        -c "$cli_env bash '$BOXA_DIR/docker-run.sh' ssh on $usage_args" \
        "$usage_transcript" </dev/null >/dev/null || usage_rc=$?
    assert_eq "ssh on $usage_args is a usage error" 1 "$usage_rc"
done

: > "$cli_ssh_add_log"
agent_add_transcript="$_TMPROOT/project-add.transcript"
printf '2\nn\na\n%s\n2\n' "$cli_key" | script -q -e -E never \
    -c "BOXA_TEST_CLI_REAL_SSH_ADD=1 $cli_env bash '$BOXA_DIR/docker-run.sh' ssh add" \
    "$agent_add_transcript" >/dev/null
assert_contains "ssh add uses the real persona key action picker" \
    'Persona key action:' "$(cat "$agent_add_transcript")"
assert_contains "ssh add binds the key to the assigned persona" \
    "key=$cli_key" "$(cat "$cli_persona_dir/cli-persona")"
cli_registry="$BOXA_SSH_KEY_REGISTRY"
_BOXA_SSH_REGISTRY_KEYS=()
BOXA_SSH_KEY_REGISTRY="$cli_registry" \
    _boxa::ssh_registry_load_project "$cli_project"
assert_eq "ssh add writes only the assigned persona key bundle" "$cli_key" \
    "${_BOXA_SSH_REGISTRY_KEYS[*]}"

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
assert_contains "container creation materializes a later default persona" \
    "_boxa::forge_apply_default_persona_to_project \"\$PROJECT_PATH\"" \
    "$docker_text"

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
    "Any process in a box with this ssh-agent forwarded can use it anywhere" \
    "$warning"
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
rm -f "$BOXA_SSH_KEY_REGISTRY"
# shellcheck disable=SC2218  # implementation is sourced above; a test stub follows
_boxa::ssh_add_keys >/dev/null 2>&1
assert_eq "declined consent never lists the SSH directory" "absent" \
    "$([ -e "$discovery_marker" ] && printf present || printf absent)"
assert_eq "declined consent still offers a manual path" \
    "noninteractive:closed:$key_dir/id_work" \
    "$(cat "$BOXA_TEST_SSH_ADD_LOG")"
assert_eq "unscoped picker does not create the Key registry" "absent" \
    "$([ -e "$BOXA_SSH_KEY_REGISTRY" ] && printf present || printf absent)"

# --- Project Key registry --------------------------------------------------

: > "$BOXA_TEST_SSH_ADD_LOG"
# shellcheck disable=SC2218  # implementation is sourced above; a test stub follows
_boxa::ssh_add_keys /work/registry >/dev/null 2>&1
assert_contains "project picker records its Project section" \
    '[/work/registry]' "$(cat "$BOXA_SSH_KEY_REGISTRY")"
assert_contains "project picker records the selected key path" \
    "key = $key_dir/id_work" "$(cat "$BOXA_SSH_KEY_REGISTRY")"
assert_not_contains "Key registry never stores private key material" \
    'private bytes must remain unread by Boxa' "$(cat "$BOXA_SSH_KEY_REGISTRY")"
assert_eq "Key registry file has mode 600" "600" \
    "$(stat -c '%a' "$BOXA_SSH_KEY_REGISTRY")"
assert_eq "Key registry parent has mode 700" "700" \
    "$(stat -c '%a' "${BOXA_SSH_KEY_REGISTRY%/*}")"

# shellcheck disable=SC2218  # implementation is sourced above; a test stub follows
_boxa::ssh_add_keys /work/registry >/dev/null 2>&1
assert_eq "recording the same Project key twice is a no-op" "1" \
    "$(grep -cFx "key = $key_dir/id_work" "$BOXA_SSH_KEY_REGISTRY")"
_boxa::ssh_registry_record_key /work/registry "$key_dir/custom.pem"
_boxa::ssh_registry_record_key /work/other-registry "$key_dir/.hidden_key"
_boxa::ssh_registry_remove_key /work/registry "$key_dir/id_work"
_boxa::ssh_registry_load_project /work/registry
assert_eq "scoped removal retains the Project's other key" \
    "$key_dir/custom.pem" "${_BOXA_SSH_REGISTRY_KEYS[*]}"
_boxa::ssh_registry_load_project /work/other-registry
assert_eq "scoped removal preserves unrelated Project sections" \
    "$key_dir/.hidden_key" "${_BOXA_SSH_REGISTRY_KEYS[*]}"

registry_lock_marker="$_TMPROOT/registry-lock.marker"
registry_lock_release="$_TMPROOT/registry-lock.release"
registry_lock_harness="$_TMPROOT/registry-lock-harness.sh"
cat > "$registry_lock_harness" <<EOF
#!/bin/bash
source "$BOXA_DIR/lib/resources.sh"
source "$BOXA_DIR/lib/ssh.sh"
hold_registry_lock() {
    : > "$registry_lock_marker"
    while [ ! -e "$registry_lock_release" ]; do sleep 0.01; done
}
_boxa::with_pid_lock "$BOXA_SSH_KEY_REGISTRY.lock" hold_registry_lock
EOF
chmod 700 "$registry_lock_harness"
"$registry_lock_harness" &
registry_lock_pid=$!
for _ in {1..100}; do
    [ -e "$registry_lock_marker" ] && break
    sleep 0.01
done
_boxa::ssh_registry_record_key /work/locked "$key_dir/id_work" &
registry_writer_pid=$!
sleep 0.05
assert_eq "Key registry mutation waits for the registry lock" alive \
    "$(kill -0 "$registry_writer_pid" 2>/dev/null \
        && printf alive || printf '%s' 'done')"
: > "$registry_lock_release"
wait "$registry_lock_pid"
wait "$registry_writer_pid"
_boxa::ssh_registry_load_project /work/locked
assert_eq "locked Key registry mutation is preserved" "$key_dir/id_work" \
    "${_BOXA_SSH_REGISTRY_KEYS[*]}"

: > "$BOXA_TEST_SSH_ADD_LOG"
_boxa::ssh_reapply_registry_keys /work/registry >/dev/null 2>&1
assert_eq "registry reapply loads only the requested Project's keys" \
    $'interactive:unused:\nnoninteractive:closed:'"$key_dir/custom.pem" \
    "$(cat "$BOXA_TEST_SSH_ADD_LOG")"

cp "$BOXA_SSH_KEY_REGISTRY" "$expected_conf"
printf '%s\n' '[/work/registry]' 'garbage' > "$BOXA_SSH_KEY_REGISTRY"
if _boxa::ssh_registry_load_project /work/registry 2>/dev/null; then
    printf 'FAIL  malformed Key registry fails closed\n'
    fail_count=$((fail_count + 1))
else
    printf 'PASS  malformed Key registry fails closed\n'
fi
assert_eq "failed registry parse exposes no key paths" "0" \
    "${#_BOXA_SSH_REGISTRY_KEYS[@]}"
mv "$expected_conf" "$BOXA_SSH_KEY_REGISTRY"

real_registry_project="$_TMPROOT/real-registry-project"
real_registry_key="$_TMPROOT/real-registry-key"
mkdir -p "$real_registry_project"
ssh-keygen -q -t ed25519 -N '' -f "$real_registry_key"
expected_real_fingerprint="$(ssh-keygen -lf "$real_registry_key.pub" \
    | awk '{ print $2 }')"
rm "$real_registry_key.pub"
_boxa::ssh_registry_record_key "$real_registry_project" "$real_registry_key"
real_restart_fingerprints="$(
    unset -f ssh-add
    _boxa::ssh_reapply_registry_keys "$real_registry_project" >/dev/null || exit 1
    ssh-add -l | awk 'NR == 1 { print $2 }'
    _boxa::ssh_reconcile_running_project_agent "$real_registry_project" \
        || exit 1
    ssh-add -l | awk 'NR == 1 { print $2 }'
    real_agent_pid="$SSH_AGENT_PID"
    kill "$real_agent_pid"
    for _ in {1..100}; do
        kill -0 "$real_agent_pid" 2>/dev/null || break
        sleep 0.01
    done
    _boxa::ssh_ensure_project_agent "$real_registry_project" || exit 1
    [ "$(_boxa::ssh_agent_state)" = empty ] || exit 1
    _boxa::ssh_reapply_registry_keys "$real_registry_project" >/dev/null || exit 1
    ssh-add -l | awk 'NR == 1 { print $2 }'
)"
assert_eq "private-only registry key reconciles before and after agent restart" \
    "$expected_real_fingerprint"$'\n'"$expected_real_fingerprint"$'\n'"$expected_real_fingerprint" \
    "$real_restart_fingerprints"

concurrent_assignment_project="$_TMPROOT/concurrent-assignment-project"
mkdir -p "$concurrent_assignment_project"
_boxa::ssh_registry_record_key \
    "$concurrent_assignment_project" "$real_registry_key"
(
    unset -f ssh-add
    _boxa::ssh_ensure_project_agent "$concurrent_assignment_project" \
        || exit 1
    _boxa::ssh_reapply_registry_keys "$concurrent_assignment_project" \
        >/dev/null || exit 1
)
export BOXA_FORGE_CONF="$BOXA_TEST_FORGE_CONF"
export BOXA_FORGE_DIR="$BOXA_TEST_FORGE_DIR"
rm -f "$BOXA_FORGE_CONF"
concurrent_outer_identity="$(
    eval "$_BOXA_TEST_RESOLVE_FORGE_IDENTITY_DEF"
    _boxa::resolve_forge_identity "$concurrent_assignment_project"
    printf '%s\n' "$_BOXA_FORGE_RESOLVED_IDENTITY_ID"
)"
assert_eq "cleanup race starts from an outer no-persona decision" "" \
    "$concurrent_outer_identity"
printf '[%s]\nforge = on\nidentity = concurrent-persona\n' \
    "$concurrent_assignment_project" > "$BOXA_FORGE_CONF"
concurrent_assignment_state="$(
    unset -f ssh-add
    eval "$_BOXA_TEST_RESOLVE_FORGE_IDENTITY_DEF"
    cleanup_status=0
    _boxa::forge_with_catalog_lock \
        _boxa::ssh_clear_unassigned_project_locked \
        "$concurrent_assignment_project" || cleanup_status=$?
    printf '%s\n' "$cleanup_status"
    _boxa::ssh_registry_load_project "$concurrent_assignment_project" \
        || exit 1
    printf '%s\n' "${_BOXA_SSH_REGISTRY_KEYS[*]}"
    _boxa::ssh_resolve_project_agent "$concurrent_assignment_project" \
        || exit 1
    ssh-add -l | awk 'NR == 1 { print $2 }'
)"
assert_eq "locked cleanup preserves a concurrently assigned persona's registry and running agent" \
    2$'\n'"$real_registry_key"$'\n'"$expected_real_fingerprint" \
    "$concurrent_assignment_state"
unset BOXA_FORGE_CONF BOXA_FORGE_DIR

project_picker_marker="$_TMPROOT/project-picker-called"
project_missing_status="$(
    # shellcheck disable=SC2317  # stubs are invoked indirectly by the helper
    _boxa::ssh_ensure_project_agent() { return 0; }
    # shellcheck disable=SC2317  # stub is invoked indirectly by the helper
    _boxa::ssh_agent_state() { printf 'empty\n'; }
    # shellcheck disable=SC2317  # stub is invoked indirectly by the helper
    _boxa::ssh_reapply_registry_keys() { return 2; }
    # shellcheck disable=SC2317  # defensive stub detects an indirect call
    _boxa::ssh_add_keys() { : > "$project_picker_marker"; }
    _boxa::ssh_add_project_keys_if_agent_unready /work/missing
    printf '%s\n' "$?"
)"
assert_eq "missing Project registry is reported for persona guidance" \
    "2" "$project_missing_status"
assert_eq "missing Project registry never opens the legacy key picker" \
    "absent" "$([ -e "$project_picker_marker" ] && printf present || printf absent)"

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

BOXA_TEST_CONTAINER_IDENTITY=user
BOXA_TEST_CONTAINER_KEYS='256 SHA256:first work@example (ED25519)'
docker() {
    case "${1:-}:${2:-}" in
        inspect:-f)
            case "$BOXA_TEST_CONTAINER_IDENTITY" in
                dedicated) printf '%s\n' /tmp/boxa-agent ;;
                user) printf '%s\n' /tmp/ssh-agent.sock ;;
            esac
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
assert_eq "old user-agent mount is not accepted as a Project agent" \
    "SSH: gate off (enable: boxa ssh on)" \
    "$(_boxa::existing_container_ssh_status boxa-app)"
BOXA_TEST_CONTAINER_KEYS=
assert_eq "empty old user-agent mount remains outside the binary gate" \
    "SSH: gate off (enable: boxa ssh on)" \
    "$(_boxa::existing_container_ssh_status boxa-app)"
BOXA_TEST_CONTAINER_IDENTITY=dedicated
BOXA_TEST_CONTAINER_KEYS='256 SHA256:agent boxa-agent@test (ED25519)'
assert_eq "existing enabled container reports Project-agent fingerprints" \
    "SSH: gate on; per-project ssh-agent running (persona 'test-persona' keys: SHA256:agent)" \
    "$(_boxa::existing_container_ssh_status boxa-app)"
_boxa::container_project_path() { printf '/work/named\n'; }
assert_eq "named attach resolves the owning persona from the Container Project" \
    "SSH: gate on; per-project ssh-agent running (persona 'named-persona' keys: SHA256:agent)" \
    "$(PROJECT_PATH='' _boxa::existing_container_ssh_status boxa-named)"
BOXA_TEST_CONTAINER_KEYS=
assert_eq "existing empty Project agent suggests the key picker" \
    "SSH: gate on; per-project ssh-agent running (persona 'test-persona', no keys) — run 'boxa ssh add'" \
    "$(_boxa::existing_container_ssh_status boxa-app)"
BOXA_TEST_CONTAINER_IDENTITY=none
seed_conf 'gate=on'
assert_eq "existing off-mode container names that no agent is forwarded" \
    "SSH: gate off (enable: boxa ssh on)" \
    "$(_boxa::existing_container_ssh_status boxa-app)"

assert_eq "every existing-container attach prints SSH state" "5" \
    "$(grep -c '_boxa::print_existing_container_ssh_status' \
        "$BOXA_DIR/docker-run.sh")"

# shellcheck disable=SC2016  # matching literal shell source
assert_contains "CLI exposes standalone boxa ssh add" \
    'if [ "$SSH_ACTION" = add ]' "$docker_text"
assert_contains "bash completion exposes ssh add" \
    'compgen -W "add off on"' "$(cat "$BOXA_DIR/completions/boxa.bash")"
assert_contains "bash completion exposes ssh --pick" \
    'compgen -W "--global --pick' "$(cat "$BOXA_DIR/completions/boxa.bash")"
assert_contains "zsh completion exposes ssh add" \
    "'add:Add keys to the host SSH agent'" "$(cat "$BOXA_DIR/completions/_boxa")"
assert_contains "zsh completion names the per-project ssh-agent process" \
    "'on:Forward the per-project ssh-agent'" \
    "$(cat "$BOXA_DIR/completions/_boxa")"
assert_contains "zsh completion exposes ssh --pick" \
    '--pick:Select known Projects interactively' \
    "$(cat "$BOXA_DIR/completions/_boxa")"

if [ "$fail_count" -gt 0 ]; then
    printf '\n%d test(s) failed.\n' "$fail_count"
    exit 1
fi

printf '\nAll SSH tests passed.\n'
