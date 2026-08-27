#!/bin/bash
# Plain-bash assertions for the forge credential store, gate, and CLI surface.
# Usage: bash tests/forge.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOXA_DIR="$SCRIPT_DIR/.."
# shellcheck source-path=SCRIPTDIR source=../lib/allowlist.sh disable=SC1091
source "$BOXA_DIR/lib/allowlist.sh"
# shellcheck source-path=SCRIPTDIR source=../lib/resources.sh disable=SC1091
source "$BOXA_DIR/lib/resources.sh"
# shellcheck source-path=SCRIPTDIR source=../lib/ssh.sh disable=SC1091
source "$BOXA_DIR/lib/ssh.sh"
# shellcheck source-path=SCRIPTDIR source=../lib/forge.sh disable=SC1091
source "$BOXA_DIR/lib/forge.sh"

_TMPROOT="$(mktemp -d)"
export BOXA_FORGE_CONF="$_TMPROOT/forge.conf"
export BOXA_FORGE_DIR="$_TMPROOT/forge"
export BOXA_SSH_CONF="$_TMPROOT/ssh.conf"
export BOXA_SSH_KEY_REGISTRY="$_TMPROOT/ssh-key-registry"
# shellcheck disable=SC2034  # consumed by sourced allowlist helpers
ALLOWLIST_HOST_FILE="$_TMPROOT/allowed-domains.conf"
trap 'rm -rf "$_TMPROOT"' EXIT

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

assert_true() {
    local label="$1"
    shift
    if "$@"; then
        printf 'PASS  %s\n' "$label"
    else
        printf 'FAIL  %s\n' "$label"
        fail_count=$((fail_count + 1))
    fi
}

assert_secret_absent() {
    local label="$1" secret="$2" path="$3"
    if ! grep -qF -- "$secret" "$path"; then
        printf 'PASS  %s\n' "$label"
    else
        printf 'FAIL  %s (secret was exposed)\n' "$label"
        fail_count=$((fail_count + 1))
    fi
}

assert_file_contains() {
    local label="$1" needle="$2" path="$3"
    if grep -qF -- "$needle" "$path"; then
        printf 'PASS  %s\n' "$label"
    else
        printf 'FAIL  %s\n' "$label"
        fail_count=$((fail_count + 1))
    fi
}

seed_conf() {
    : > "$BOXA_FORGE_CONF"
    local line
    for line in "$@"; do
        printf '%s\n' "$line" >> "$BOXA_FORGE_CONF"
    done
}

resolve_gate() {
    _boxa::resolve_forge_gate "$1"
    printf '%s\n' "$_BOXA_FORGE_GATE"
}

# --- Strict gate resolution ------------------------------------------------

rm -f "$BOXA_FORGE_CONF"
assert_eq "missing config defaults off" "off" "$(resolve_gate /work/app)"
assert_eq "missing config source is default" "default" "$_BOXA_FORGE_SOURCE"

seed_conf "forge=on"
assert_eq "global opt-in enables forge access" "on" "$(resolve_gate /work/app)"
_boxa::resolve_forge_gate /work/app
assert_eq "global source is reported" "global" "$_BOXA_FORGE_SOURCE"

seed_conf "forge=on" "[/work/app]" "forge=off"
assert_eq "project off overrides global on" "off" "$(resolve_gate /work/app)"
assert_eq "other project inherits global on" "on" "$(resolve_gate /work/other)"

seed_conf "forge=off" "[/work/app]" "forge=on"
assert_eq "project on overrides global off" "on" "$(resolve_gate /work/app)"
_boxa::resolve_forge_gate /work/app
assert_eq "project source is reported" "project" "$_BOXA_FORGE_SOURCE"
if _boxa::forge_usage_configured; then
    printf 'PASS  Project forge gate counts as Agent identity usage\n'
else
    printf 'FAIL  Project forge gate counts as Agent identity usage\n'
    fail_count=$((fail_count + 1))
fi

seed_conf "forge=off" "[/work/app]" "forge=off"
if _boxa::forge_usage_configured; then
    printf 'FAIL  off forge gates do not count as Agent identity usage\n'
    fail_count=$((fail_count + 1))
else
    printf 'PASS  off forge gates do not count as Agent identity usage\n'
fi

seed_conf "forge=on"
if _boxa::forge_usage_configured; then
    printf 'PASS  global forge gate counts as Agent identity usage\n'
else
    printf 'FAIL  global forge gate counts as Agent identity usage\n'
    fail_count=$((fail_count + 1))
fi

for invalid_line in "forge=maybe" "not an assignment" "unknown=on" "[relative]" "[/broken"; do
    seed_conf "forge=on" "$invalid_line"
    assert_eq "invalid config falls back off: $invalid_line" "off" \
        "$(resolve_gate /work/app)"
done
_boxa::resolve_forge_gate /work/app
assert_eq "invalid config source is reported" "invalid" "$_BOXA_FORGE_SOURCE"
if _boxa::forge_usage_configured; then
    printf 'FAIL  invalid forge config never counts as Agent identity usage\n'
    fail_count=$((fail_count + 1))
else
    printf 'PASS  invalid forge config never counts as Agent identity usage\n'
fi

seed_conf 'forge=on' 'identity=default-persona' '[/work/app]' \
    'identity=project-persona' '[/work/none]' 'identity=none'
assert_eq "persona keys keep a valid config enabled" "on" \
    "$(resolve_gate /work/app)"
_boxa::resolve_forge_identity /work/app
assert_eq "project persona assignment overrides the global default" \
    "project-persona" "$_BOXA_FORGE_RESOLVED_IDENTITY_ID"
_boxa::resolve_forge_identity /work/other
assert_eq "other project falls back to the global default persona" \
    "default-persona" "$_BOXA_FORGE_RESOLVED_IDENTITY_ID"
_boxa::resolve_forge_identity /work/none
assert_eq "explicit project none overrides the global default persona" "" \
    "$_BOXA_FORGE_RESOLVED_IDENTITY_ID"
seed_conf 'forge=on'
_boxa::resolve_forge_identity /work/app github
assert_eq "missing assignment and default resolve to none" "" \
    "$_BOXA_FORGE_RESOLVED_IDENTITY_ID"

for invalid_line in \
        'identity=bad/name' \
        'identity=bad:name' \
        'github=github:legacy' \
        'unknown=persona'; do
    seed_conf 'forge=on' "$invalid_line"
    assert_eq "invalid identity config falls back off: $invalid_line" "off" \
        "$(resolve_gate /work/app)"
done
seed_conf 'forge=on' 'identity=first' 'identity=second'
assert_eq "duplicate identity key invalidates the complete config" "off" \
    "$(resolve_gate /work/app)"
_boxa::resolve_forge_identity /work/app github
assert_eq "invalid config resolves no identity" "" \
    "$_BOXA_FORGE_RESOLVED_IDENTITY_ID"

marker="$_TMPROOT/should-not-exist"
seed_conf "forge=\$(touch $marker)"
resolve_gate /work/app >/dev/null
assert_eq "config is never sourced" "absent" \
    "$([ -e "$marker" ] && printf present || printf absent)"

for gate_state in on off; do
    _boxa::write_forge_conf global '' "$gate_state"
    assert_eq "global config roundtrips $gate_state" "$gate_state" \
        "$(resolve_gate /work/app)"
done

# --- Structure-preserving config writer -----------------------------------

expected_conf="$_TMPROOT/expected.conf"
printf '%s' $'# global\nforge = off # replace\n[/work/app]\nforge=off\nkeep = bytes' \
    > "$BOXA_FORGE_CONF"
printf '%s' $'# global\nforge = on\n[/work/app]\nforge=off\nkeep = bytes' \
    > "$expected_conf"
_boxa::write_forge_conf global '' on
assert_file_eq "global writer preserves untouched bytes and final newline state" \
    "$expected_conf" "$BOXA_FORGE_CONF"
_boxa::write_forge_conf global '' on
assert_file_eq "repeated global write is idempotent" \
    "$expected_conf" "$BOXA_FORGE_CONF"

printf '%s\n' '# keep global' 'forge = on' '[/work/app]' 'forge = off' \
    'foreign = preserve' '[/work/other]' 'forge = off' > "$BOXA_FORGE_CONF"
printf '%s\n' '# keep global' 'forge = on' '[/work/app]' \
    'foreign = preserve' 'forge = on' '[/work/other]' 'forge = off' \
    > "$expected_conf"
_boxa::write_forge_conf project /work/app on
assert_file_eq "project writer replaces only target key and preserves foreign bytes" \
    "$expected_conf" "$BOXA_FORGE_CONF"

printf '%s\n' '# keep' '[/work/other]' 'forge = on' > "$BOXA_FORGE_CONF"
printf '%s\n' '# keep' '[/work/other]' 'forge = on' '[/work/new]' \
    'forge = off' > "$expected_conf"
_boxa::write_forge_conf project /work/new off
assert_file_eq "project writer appends one missing section" \
    "$expected_conf" "$BOXA_FORGE_CONF"

cp "$BOXA_FORGE_CONF" "$expected_conf"
if _boxa::write_forge_conf project '/work/C#' on 2>/dev/null; then
    printf 'FAIL  writer rejects an unrepresentable project path\n'
    fail_count=$((fail_count + 1))
else
    printf 'PASS  writer rejects an unrepresentable project path\n'
fi
assert_file_eq "rejected writer leaves config byte-identical" \
    "$expected_conf" "$BOXA_FORGE_CONF"

# Pause the first writer after its read so a second scope update overlaps it.
# The lock must keep both updates; an unlocked read-modify-rename loses the
# second writer when the paused first writer resumes.
seed_conf 'forge=off' '[/work/app]' 'forge=off'
forge_race_marker="$_TMPROOT/forge-race.marker"
forge_race_release="$_TMPROOT/forge-race.release"
forge_race_worker="$_TMPROOT/forge-race-worker.sh"
cat > "$forge_race_worker" <<EOF
#!/bin/bash
set -euo pipefail
source "$BOXA_DIR/lib/resources.sh"
source "$BOXA_DIR/lib/forge.sh"
if [ "\${BOXA_TEST_PAUSE:-}" = 1 ]; then
    eval "\$(declare -f _boxa::remove_conf_keys | sed '1s/_boxa::remove_conf_keys/_boxa::remove_conf_keys_real/')"
    _boxa::remove_conf_keys() {
        _boxa::remove_conf_keys_real "\$@"
        : > "\$BOXA_TEST_MARKER"
        while [ ! -e "\$BOXA_TEST_RELEASE" ]; do sleep 0.05; done
    }
fi
_boxa::write_forge_conf "\$1" "\$2" "\$3"
EOF
chmod 700 "$forge_race_worker"
BOXA_TEST_PAUSE=1 BOXA_TEST_MARKER="$forge_race_marker" \
    BOXA_TEST_RELEASE="$forge_race_release" \
    "$forge_race_worker" global '' on &
first_forge_pid=$!
for _ in {1..100}; do [ -e "$forge_race_marker" ] && break; sleep 0.05; done
"$forge_race_worker" project /work/app on &
second_forge_pid=$!
sleep 0.1
: > "$forge_race_release"
wait "$first_forge_pid"
wait "$second_forge_pid"
assert_eq "concurrent global update survives a project gate write" "on" \
    "$(resolve_gate /work/other)"
assert_eq "concurrent project update survives a global gate write" "on" \
    "$(resolve_gate /work/app)"

forge_signal_marker="$_TMPROOT/forge-signal.marker"
forge_signal_release="$_TMPROOT/forge-signal.release"
BOXA_TEST_PAUSE=1 BOXA_TEST_MARKER="$forge_signal_marker" \
    BOXA_TEST_RELEASE="$forge_signal_release" \
    "$forge_race_worker" global '' off &
forge_signal_pid=$!
for _ in {1..100}; do [ -e "$forge_signal_marker" ] && break; sleep 0.05; done
forge_lock_owner="$(cat "$BOXA_FORGE_CONF.lock/owner")"
kill -TERM "$forge_lock_owner"
forge_signal_status=0
wait "$forge_signal_pid" || forge_signal_status=$?
assert_eq "interrupted forge writer exits for the terminating signal" "143" \
    "$forge_signal_status"
assert_eq "interrupted forge writer removes its lock" "absent" \
    "$([ -e "$BOXA_FORGE_CONF.lock" ] && printf present || printf absent)"
_boxa::write_forge_conf global '' off
assert_eq "forge update succeeds after interrupted-owner cleanup" "off" \
    "$(resolve_gate /work/other)"

mkdir -p "$BOXA_FORGE_CONF.lock"
printf '999999999\n' > "$BOXA_FORGE_CONF.lock/owner"
_boxa::write_forge_conf project /work/app off
assert_eq "forge writer reclaims a lock owned by a dead process" "off" \
    "$(resolve_gate /work/app)"
assert_eq "reclaimed forge lock is removed after success" "absent" \
    "$([ -e "$BOXA_FORGE_CONF.lock" ] && printf present || printf absent)"

# Project purge keeps the catalog lock while waiting inside the SSH registry
# critical section, preserving the catalog -> registry lock order.
purge_lock_project=/work/purge-lock
printf '[%s]\nforge = on\n' "$purge_lock_project" > "$BOXA_FORGE_CONF"
printf '[%s]\ngate = on\n' "$purge_lock_project" > "$BOXA_SSH_CONF"
printf '[%s]\nkey = /keys/purge-lock\n' "$purge_lock_project" \
    > "$BOXA_SSH_KEY_REGISTRY"
purge_lock_marker="$_TMPROOT/purge-lock.marker"
purge_lock_release="$_TMPROOT/purge-lock.release"
purge_catalog_acquired="$_TMPROOT/purge-catalog.acquired"
eval "$(declare -f _boxa::ssh_purge_project_state_locked \
    | sed '1s/_boxa::ssh_purge_project_state_locked/_boxa::ssh_purge_project_state_locked_real/')"
_boxa::ssh_purge_project_state_locked() {
    : > "$purge_lock_marker"
    while [ ! -e "$purge_lock_release" ]; do sleep 0.01; done
    _boxa::ssh_purge_project_state_locked_real "$@"
}
# shellcheck disable=SC2317  # invoked dynamically by the catalog lock helper
_boxa::test_mark_catalog_acquired() {
    : > "$purge_catalog_acquired"
}
_boxa::forge_purge_project_state "$purge_lock_project" >/dev/null &
purge_lock_pid=$!
for _ in {1..100}; do [ -e "$purge_lock_marker" ] && break; sleep 0.01; done
_boxa::forge_with_catalog_lock _boxa::test_mark_catalog_acquired &
purge_catalog_pid=$!
sleep 0.1
assert_eq "Project purge retains the catalog lock inside the registry lock" \
    absent "$([ -e "$purge_catalog_acquired" ] && printf present || printf absent)"
: > "$purge_lock_release"
wait "$purge_lock_pid"
wait "$purge_catalog_pid"
assert_eq "catalog waiter proceeds after atomic Project purge" \
    present "$([ -e "$purge_catalog_acquired" ] && printf present || printf absent)"
eval "$(declare -f _boxa::ssh_purge_project_state_locked_real \
    | sed '1s/_boxa::ssh_purge_project_state_locked_real/_boxa::ssh_purge_project_state_locked/')"
unset -f _boxa::ssh_purge_project_state_locked_real \
    _boxa::test_mark_catalog_acquired

# --- Default persona SSH gate synthesis -----------------------------------

default_key="$_TMPROOT/default-key"
ssh-keygen -q -t ed25519 -N '' -C default-key -f "$default_key"
_boxa::forge_write_persona default-keyed agent "$default_key" \
    github-token default-user 1 '' '' '' ''
_boxa::forge_write_persona default-keyless other '' \
    github-token keyless-user 1 '' '' '' ''

default_keyed_project="$_TMPROOT/default-keyed-project"
: > "$BOXA_FORGE_CONF"
printf '[%s]\n' "$default_keyed_project" > "$BOXA_SSH_CONF"
_boxa::forge_default default-keyed >/dev/null
assert_contains "default persona writes the global forge gate" 'forge = on' \
    "$(< "$BOXA_FORGE_CONF")"
_boxa::resolve_forge_gate "$default_keyed_project"
assert_eq "default persona enables the global forge gate" on \
    "$_BOXA_FORGE_GATE"
_boxa::resolve_ssh_gate "$default_keyed_project"
assert_eq "keyed default persona turns a default-resolving Project SSH gate on" \
    on "$_BOXA_SSH_GATE"

default_keyless_project="$_TMPROOT/default-keyless-project"
: > "$BOXA_FORGE_CONF"
printf 'gate = on\n[%s]\n' "$default_keyless_project" > "$BOXA_SSH_CONF"
_boxa::ssh_registry_replace_project "$default_keyless_project" "$default_key"
_boxa::forge_default default-keyless >/dev/null
assert_not_contains "keyless default does not materialize a Project off gate" \
    'gate = off' "$(< "$BOXA_SSH_CONF")"
_boxa::resolve_ssh_gate "$default_keyless_project"
assert_eq "keyless default leaves the Project on through the global SSH gate" \
    on "$_BOXA_SSH_GATE"
assert_eq "keyless default preserves the global SSH source" global \
    "$_BOXA_SSH_SOURCE"
_boxa::ssh_registry_load_project "$default_keyless_project"
assert_eq "keyless default clears stale Project key paths" 0 \
    "${#_BOXA_SSH_REGISTRY_KEYS[@]}"

default_explicit_project="$_TMPROOT/default-explicit-project"
: > "$BOXA_FORGE_CONF"
printf 'gate = on\n[%s]\ngate = on\n' "$default_explicit_project" \
    > "$BOXA_SSH_CONF"
_boxa::forge_default default-keyless >/dev/null
_boxa::resolve_ssh_gate "$default_explicit_project"
assert_eq "synthesized off still replaces an explicit Project SSH gate" off \
    "$_BOXA_SSH_GATE"
assert_eq "synthesized off keeps the explicit Project SSH source" project \
    "$_BOXA_SSH_SOURCE"

# --- Persona catalog -------------------------------------------------------

# ADR 0034 intentionally makes the pre-persona storage and assignment grammar
# unreadable. Its replacement coverage lives in persona.sh and the real-PTY
# migration module; ADR 0033 assertions cannot coexist with the new grammar.
if bash "$SCRIPT_DIR/persona.sh"; then
    printf 'PASS  persona storage and grammar suite\n'
else
    printf 'FAIL  persona storage and grammar suite\n'
    fail_count=$((fail_count + 1))
fi

# --- CLI registration and completions -------------------------------------

docker_text="$(cat "$BOXA_DIR/docker-run.sh")"
# Match the literal source expression, not this test process's BOXA_DIR.
# shellcheck disable=SC2016
assert_contains "CLI sources forge implementation" 'source "$BOXA_DIR/lib/forge.sh"' \
    "$docker_text"
assert_contains "CLI registers forge mode" 'forge)   MODE="forge"' "$docker_text"
assert_contains "CLI exposes the global forge identity list" \
    '_boxa::forge_list' "$docker_text"
assert_contains "CLI documents forge list" 'boxa forge list' "$docker_text"
assert_contains "CLI documents persona key management" \
    'boxa forge keys <name>' "$docker_text"
# shellcheck disable=SC2016  # matching the literal CLI dispatch source
assert_contains "CLI dispatches persona key management" \
    '_boxa::forge_keys "$FORGE_IDENTITY"' "$docker_text"
assert_contains "CLI documents forge use" 'boxa forge use [<name>]' "$docker_text"
assert_contains "CLI documents forge default" 'boxa forge default <name>' \
    "$docker_text"
assert_contains "CLI documents forge add" 'boxa forge add' "$docker_text"
assert_contains "CLI documents forge remove" \
    'boxa forge remove <name> [--force]' "$docker_text"
assert_contains "CLI documents explicit forge status" \
    'boxa forge status' "$docker_text"
assert_contains "CLI rejects arguments to forge list" \
    'Usage: boxa forge list' "$docker_text"
assert_contains "CLI rejects arguments to forge status" \
    'Usage: boxa forge status' "$docker_text"
# shellcheck disable=SC2016  # matching literal CLI source
assert_contains "explicit forge status shares the bare forge dispatch" \
    '|| [ "$FORGE_ACTION" = setup ]; then' \
    "$docker_text"
assert_contains "CLI validates forge remove arguments" \
    'Usage: boxa forge remove <name> [--force]' "$docker_text"
assert_contains "CLI warns running Projects about required restart" \
    "Forge access change takes effect after boxa stop && boxa" "$docker_text"
assert_contains "CLI documents environment precedence over config files" \
    "Stored environment credentials win" "$docker_text"
# shellcheck disable=SC2016  # matching the literal Docker mount source
assert_contains "glab config uses its canonical project volume path" \
    '${BOXA_VOL_GLAB}:/home/node/.config/glab-cli' "$docker_text"
# shellcheck disable=SC2016  # matching the literal legacy Docker mount source
assert_not_contains "legacy glab config mount is absent" \
    '${BOXA_VOL_GLAB}:/home/node/.config/glab"' "$docker_text"
entrypoint_text="$(cat "$BOXA_DIR/scripts/boxa-entrypoint.sh")"
assert_contains "entrypoint gives node ownership of the GitHub config volume" \
    '/home/node/.config/gh' "$entrypoint_text"
assert_contains "entrypoint gives node ownership of the GitLab config volume" \
    '/home/node/.config/glab-cli' "$entrypoint_text"
attach_body="$(sed -n '/^attach_to_container() {/,/^}/p' "$BOXA_DIR/docker-run.sh")"
# shellcheck disable=SC2016  # matching the literal attach helper source
assert_contains "every attach checks forge token expiry before exec" \
    '_boxa::forge_token_expiry_heads_up "$project_path"' "$attach_body"
# shellcheck disable=SC2016  # matching literal help text
assert_contains "CLI documents the container-creation limitation" \
    'run `boxa stop && boxa` to apply them' "$docker_text"
assert_contains "bash completion exposes forge actions" \
    'compgen -W "status add list keys use default remove set unset setup checklist adopt on off"' \
    "$(cat "$BOXA_DIR/completions/boxa.bash")"
assert_contains "zsh completion exposes forge set" \
    "'set:Store or rotate a forge credential'" "$(cat "$BOXA_DIR/completions/_boxa")"
assert_contains "zsh completion exposes forge add" \
    "'add:Register a verified forge identity'" "$(cat "$BOXA_DIR/completions/_boxa")"
assert_contains "zsh completion exposes forge remove" \
    "'remove:Remove a forge identity'" "$(cat "$BOXA_DIR/completions/_boxa")"
assert_contains "zsh completion exposes forge status" \
    "'status:Open the forge persona and Project dashboard'" \
    "$(cat "$BOXA_DIR/completions/_boxa")"
assert_contains "zsh completion exposes forge keys" \
    "'keys:Manage persona SSH keys'" \
    "$(cat "$BOXA_DIR/completions/_boxa")"
# shellcheck disable=SC2016  # matching literal CLI source
assert_contains "CLI exposes guided forge setup" \
    '_boxa::forge_dashboard "$forge_current_path" "$FORGE_NAME"' \
    "$docker_text"
# shellcheck disable=SC2016  # matching literal doctor follow-up source
assert_contains "doctor Agent identity follow-up reuses forge dashboard" \
    '_boxa::forge_dashboard "$PWD"' \
    "$(cat "$BOXA_DIR/scripts/ensure-agent-identity.sh")"
# shellcheck disable=SC2016  # matching literal CLI source
assert_contains "CLI exposes individual forge checklists" \
    '_boxa::forge_checklist "$FORGE_NAME"' "$docker_text"
# shellcheck disable=SC2016  # matching literal CLI source
assert_contains "CLI exposes consent-first host token adoption" \
    '_boxa::forge_adopt_existing "$FORGE_NAME"' "$docker_text"
# shellcheck disable=SC2016  # matching literal CLI source
assert_contains "CLI exposes interactive identity assignment" \
    '_boxa::forge_use "$FORGE_IDENTITY" "$forge_current_path"' "$docker_text"
# shellcheck disable=SC2016  # matching literal CLI source
assert_contains "CLI exposes global identity defaults" \
    '_boxa::forge_default "$FORGE_IDENTITY"' "$docker_text"
# shellcheck disable=SC2016  # matching literal CLI source
assert_contains "CLI exposes guarded identity removal" \
    '_boxa::forge_remove "$FORGE_IDENTITY" "$FORGE_FORCE"' "$docker_text"
# shellcheck disable=SC2016  # matching literal CLI source
assert_contains "CLI exposes kind-based identity registration" \
    '_boxa::forge_add "$FORGE_NAME"' "$docker_text"
# shellcheck disable=SC2016  # matching literal CLI source
assert_contains "CLI applies forge gates through SSH reconciliation" \
    '_boxa::forge_set_gate "$forge_scope" "$forge_path" "$FORGE_ACTION"' \
    "$docker_text"

if [ "$fail_count" -gt 0 ]; then
    printf '\n%d test(s) failed.\n' "$fail_count"
    exit 1
fi

printf '\nAll forge tests passed.\n'
