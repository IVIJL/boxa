#!/bin/bash
# Plain-bash assertions for the persona store and forge.conf grammar.
# Usage: bash tests/persona.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOXA_DIR="$SCRIPT_DIR/.."
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
export BOXA_SSH_AGENTS_DIR="$_TMPROOT/ssh-agents"
persona_agent_pid=''
cleanup() {
    [ -z "$persona_agent_pid" ] || kill "$persona_agent_pid" 2>/dev/null || true
    rm -rf "$_TMPROOT"
}
trap cleanup EXIT
fail_count=0
pass_count=0

check() {
    local label="$1"
    shift
    if "$@"; then
        printf 'PASS  %s\n' "$label"
        pass_count=$((pass_count + 1))
    else
        printf 'FAIL  %s\n' "$label"
        fail_count=$((fail_count + 1))
    fi
}

check_eq() {
    local label="$1" expected="$2" actual="$3"
    check "$label" test "$expected" = "$actual"
}

key="$_TMPROOT/id_ed25519"
ssh-keygen -q -t ed25519 -N '' -C persona-test -f "$key"
now="$(date +%s)"
keys="$key"$'\n'"$_TMPROOT/missing-key"

_boxa::forge_write_persona agent agent "$keys" github-token octocat \
    "$((now - 172800))" gitlab-token robot gitlab.example \
    "$((now - 86400))"
persona="$BOXA_FORGE_DIR/identities/agent"
github_token_file="$BOXA_FORGE_DIR/tokens/agent.github"
gitlab_token_file="$BOXA_FORGE_DIR/tokens/agent.gitlab"
persona_text="$(< "$persona")"
check_eq 'persona directory is 0700' 700 \
    "$(stat -c '%a' "$BOXA_FORGE_DIR/identities")"
check_eq 'persona file is 0600' 600 "$(stat -c '%a' "$persona")"
check 'persona file records chosen name' grep -qFx name=agent "$persona"
check 'persona grammar is version 3' grep -qFx version=3 "$persona"
check 'persona file contains no GitHub token' test \
    "${persona_text#*github-token}" = "$persona_text"
check 'persona file contains no GitLab token' test \
    "${persona_text#*gitlab-token}" = "$persona_text"
check 'persona file records GitLab host' grep -qFx \
    gitlab_host=gitlab.example "$persona"
check_eq 'persona file records both key references' 2 \
    "$(grep -c '^key=' "$persona")"
check_eq 'token directory is 0700' 700 \
    "$(stat -c '%a' "$BOXA_FORGE_DIR/tokens")"
check_eq 'GitHub token file is 0600' 600 \
    "$(stat -c '%a' "$github_token_file")"
check_eq 'GitLab token file is 0600' 600 \
    "$(stat -c '%a' "$gitlab_token_file")"
check_eq 'GitHub token lives in its token file' github-token \
    "$(< "$github_token_file")"
check_eq 'GitLab token lives in its token file' gitlab-token \
    "$(< "$gitlab_token_file")"

_boxa::forge_load_persona agent
check_eq 'persona name round-trips' agent "$_BOXA_FORGE_PERSONA_NAME"
check_eq 'persona kind round-trips' agent "$_BOXA_FORGE_IDENTITY_KIND"
check_eq 'GitHub username round-trips' octocat \
    "$_BOXA_FORGE_GITHUB_USERNAME"
check_eq 'GitLab username round-trips' robot \
    "$_BOXA_FORGE_GITLAB_USERNAME"
check_eq 'key references round-trip' "$keys" "$_BOXA_FORGE_PERSONA_KEYS"
check_eq 'GitHub token round-trips from split storage' github-token \
    "$_BOXA_FORGE_GITHUB_TOKEN"
check_eq 'GitLab token round-trips from split storage' gitlab-token \
    "$_BOXA_FORGE_GITLAB_TOKEN"
check_eq 'long tokens are masked with stable ends' 'gho_PMhq…eZn' \
    "$(_boxa::forge_mask_token gho_PMhq123456789eZn)"

persona_before="$(< "$persona")"
github_token_before="$(< "$github_token_file")"
gitlab_token_before="$(< "$gitlab_token_file")"
metadata_failure_marker="$_TMPROOT/metadata-failure"
# shellcheck disable=SC2317  # invoked indirectly by the persona writer
mv() {
    if [[ "$1" == "$persona.tmp."* && "$2" = "$persona" ]] \
            && [ ! -e "$metadata_failure_marker" ]; then
        : > "$metadata_failure_marker"
        return 1
    fi
    command mv "$@"
}
if _boxa::forge_write_persona agent agent "$keys" rotated-github octocat \
        "$now" rotated-gitlab robot gitlab.example "$now" true; then
    check 'failed persona metadata publication is rejected' false
else
    check 'failed persona metadata publication is rejected' true
fi
unset -f mv
check_eq 'failed metadata publication rolls back persona metadata' \
    "$persona_before" "$(< "$persona")"
check_eq 'failed metadata publication rolls back the GitHub token' \
    "$github_token_before" "$(< "$github_token_file")"
check_eq 'failed metadata publication rolls back the GitLab token' \
    "$gitlab_token_before" "$(< "$gitlab_token_file")"
_boxa::forge_load_persona agent
check_eq 'rolled-back persona and token pair remains readable' github-token \
    "$_BOXA_FORGE_GITHUB_TOKEN"

signal_publication_marker="$_TMPROOT/signal-publication-marker"
signal_publication_pid="$_TMPROOT/signal-publication-pid"
signal_publication_release="$_TMPROOT/signal-publication-release"
# shellcheck disable=SC2317  # invoked indirectly by the persona writer
mv() {
    if [[ "$1" == "$github_token_file.tmp."* \
            && "$2" = "$github_token_file" ]] \
            && [ "$(< "$1")" = interrupted-github ]; then
        command mv "$@" || return
        printf '%s\n' "$BASHPID" > "$signal_publication_pid"
        : > "$signal_publication_marker"
        while [ ! -e "$signal_publication_release" ]; do
            sleep 0.01
        done
        return
    fi
    command mv "$@"
}
_boxa::forge_write_persona agent agent "$keys" interrupted-github octocat \
    "$now" rotated-gitlab robot gitlab.example "$now" true &
signal_writer_pid=$!
for _ in {1..500}; do
    [ ! -e "$signal_publication_marker" ] || break
    sleep 0.01
done
if [ -s "$signal_publication_pid" ]; then
    kill -TERM "$(< "$signal_publication_pid")" 2>/dev/null || true
else
    : > "$signal_publication_release"
fi
wait "$signal_writer_pid" 2>/dev/null || true
unset -f mv
check_eq 'signal during token publication rolls back the GitHub token' \
    "$github_token_before" "$(< "$github_token_file")"
check_eq 'signal during token publication preserves persona metadata' \
    "$persona_before" "$(< "$persona")"
_boxa::forge_load_persona agent
check_eq 'signal-interrupted persona and token pair remains readable' \
    github-token "$_BOXA_FORGE_GITHUB_TOKEN"

legacy_persona="$BOXA_FORGE_DIR/identities/legacy-v2"
printf '%s\n' 'version=2' 'name=legacy-v2' 'kind=mine' \
    'github_created_at=10' 'github_username=legacy-user' \
    'github_token=legacy-secret' 'gitlab_created_at=' 'gitlab_host=' \
    'gitlab_username=' 'gitlab_token=' > "$legacy_persona"
chmod 600 "$legacy_persona"
_boxa::forge_load_persona legacy-v2
check_eq 'version 2 persona remains readable before its first write' \
    legacy-secret "$_BOXA_FORGE_GITHUB_TOKEN"
_boxa::forge_write_identity github mine rotated-legacy-secret legacy-user '' \
    11 token legacy-v2
check 'first write removes embedded legacy token' grep -qvF legacy-secret \
    "$legacy_persona"
check 'first write upgrades the persona grammar one-way' grep -qFx version=3 \
    "$legacy_persona"
check_eq 'first write relocates the rotated legacy token' \
    rotated-legacy-secret \
    "$(< "$BOXA_FORGE_DIR/tokens/legacy-v2.github")"

agent_identity_key="$_TMPROOT/agent-identity/id_ed25519"
mkdir -p "${agent_identity_key%/*}"
ssh-keygen -q -t ed25519 -N '' -C agent-identity-test \
    -f "$agent_identity_key"
export BOXA_AGENT_KEY="$agent_identity_key"
picked_keys="$_TMPROOT/id_picked_a"$'\n'"$_TMPROOT/id_picked_b"
_boxa::forge_write_identity github mine picked-token picked-user '' 1 ssh \
    picked-persona "$picked_keys"
_boxa::forge_load_persona picked-persona
check_eq 'registration stores exactly the explicitly picked key paths' \
    "$picked_keys" "$_BOXA_FORGE_PERSONA_KEYS"
check 'registration does not silently attach the Agent identity key' test \
    "$_BOXA_FORGE_PERSONA_KEYS" != "$agent_identity_key"
_boxa::forge_write_identity github mine rotated-token picked-user '' 2 ssh \
    picked-persona
_boxa::forge_load_persona picked-persona
check_eq 'token rotation preserves the explicitly picked key paths' \
    "$picked_keys" "$_BOXA_FORGE_PERSONA_KEYS"
_boxa::forge_write_identity github agent agent-token agent-user '' 1 ssh \
    explicit-agent-persona "$agent_identity_key"
_boxa::forge_load_persona explicit-agent-persona
check_eq 'explicit Agent-key registration attaches the Agent identity key' \
    "$agent_identity_key" "$_BOXA_FORGE_PERSONA_KEYS"
unset BOXA_AGENT_KEY

duplicate_error="$_TMPROOT/duplicate-error"
if _boxa::forge_write_persona agent mine "$key" token user 1 '' '' '' '' \
        2> "$duplicate_error"; then
    check 'duplicate persona name is rejected' false
else
    check 'duplicate persona name is rejected' true
fi
check 'duplicate rejection explains the collision' grep -q \
    "Persona 'agent' already exists" "$duplicate_error"
if _boxa::forge_write_persona duplicate-keys mine "$key"$'\n'"$key" \
        token user 1 '' '' '' ''; then
    check 'duplicate key references are rejected' false
else
    check 'duplicate key references are rejected' true
fi
if _boxa::forge_write_persona key-only agent "$key" '' '' '' '' '' '' ''; then
    check 'key-only persona is rejected' false
else
    check 'key-only persona is rejected' true
fi

for invalid_name in '' . .. 'bad/name' 'bad:name' $'bad\nname'; do
    if _boxa::forge_validate_persona_name "$invalid_name"; then
        check "invalid persona name is rejected: $invalid_name" false
    else
        check "invalid persona name is rejected: $invalid_name" true
    fi
done

cp "$persona" "$_TMPROOT/valid-persona"
printf 'unknown=value\n' >> "$persona"
if _boxa::forge_load_persona agent; then
    check 'unknown persona field is rejected' false
else
    check 'unknown persona field is rejected' true
fi
cp "$_TMPROOT/valid-persona" "$persona"
printf 'kind=mine\n' >> "$persona"
if _boxa::forge_load_persona agent; then
    check 'duplicate persona field is rejected' false
else
    check 'duplicate persona field is rejected' true
fi
cp "$_TMPROOT/valid-persona" "$persona"

printf 'forge = on\nidentity = agent\n[/work/none]\nidentity = none\n' \
    > "$BOXA_FORGE_CONF"
_boxa::resolve_forge_identity /work/app
check_eq 'global default persona resolves' agent \
    "$_BOXA_FORGE_RESOLVED_IDENTITY_ID"
_boxa::resolve_forge_identity /work/none
check_eq 'project none overrides the default persona' '' \
    "$_BOXA_FORGE_RESOLVED_IDENTITY_ID"
printf 'forge = on\ngithub = github:octocat\n' > "$BOXA_FORGE_CONF"
_boxa::resolve_forge_gate /work/app
check_eq 'new parser fails closed on legacy assignment grammar' invalid \
    "$_BOXA_FORGE_SOURCE"
check_eq 'legacy assignment grammar forces the gate off' off \
    "$_BOXA_FORGE_GATE"

printf 'forge = off\n' > "$BOXA_FORGE_CONF"
_boxa::write_forge_conf global '' agent identity
_boxa::write_forge_conf project /work/app agent identity
_boxa::resolve_forge_gate /work/app
check_eq 'writer records one global default persona' agent \
    "$_BOXA_FORGE_GLOBAL_IDENTITY"
check_eq 'writer records one project persona assignment' agent \
    "$_BOXA_FORGE_PROJECT_IDENTITY"
check_eq 'writer emits no legacy forge slots' 0 \
    "$(grep -Ec '^(github|gitlab)[[:space:]]*=' "$BOXA_FORGE_CONF" || true)"

list_output="$(_boxa::forge_list)"
check 'list uses persona vocabulary' grep -q 'Persona: agent' <<< "$list_output"
check 'list renders both configured forges' grep -q \
    'Forges: GitHub, GitLab' <<< "$list_output"
check 'list renders token ages' grep -q \
    'Token age: GitHub 2 day(s), GitLab 1 day(s)' <<< "$list_output"
fingerprint="$(ssh-keygen -lf "$key.pub" | awk 'NR == 1 { print $2 }')"
check 'list renders a public-key fingerprint' grep -q "$fingerprint" \
    <<< "$list_output"

status_output="$(_boxa::forge_status /work/app)"
check 'status names the default persona' grep -q 'Default persona: agent' \
    <<< "$status_output"
check 'status names the Project persona assignment' grep -q \
    'Project persona assignment: agent' <<< "$status_output"
check 'status names the resolved persona' grep -q 'Resolved persona: agent' \
    <<< "$status_output"
check 'status masks the GitHub token' grep -q 'GitHub token: github-t…ken' \
    <<< "$status_output"
check 'status never prints the full GitHub token' test \
    "${status_output#*github-token}" = "$status_output"
check 'status has no pre-persona default vocabulary' test \
    "${status_output#*default identity}" = "$status_output"

# --- Whole-persona assignment write-through ------------------------------

key_a="$_TMPROOT/id_persona_a"
key_b="$_TMPROOT/id_persona_b"
ssh-keygen -q -t ed25519 -N '' -C persona-a -f "$key_a"
ssh-keygen -q -t ed25519 -N '' -C persona-b -f "$key_b"
_boxa::forge_write_persona persona-a agent "$key_a" github-a alice 1 \
    '' '' '' ''
_boxa::forge_write_persona persona-b mine "$key_b" '' '' '' \
    gitlab-b bob gitlab.example 2
_boxa::forge_write_persona token-only other '' github-c carol 3 \
    '' '' '' ''

project=/work/assignment
assignment_output="$(_boxa::forge_assign_identity persona-a "$project")"
check_eq 'keyed assignment explains SSH key forwarding consequence' \
    "Persona 'persona-a' assigned to $project; forge access is on; its SSH keys will be forwarded into this project's ssh-agent (gate on)." \
    "$assignment_output"
_boxa::resolve_forge_gate "$project"
check_eq 'assignment turns the Project forge gate on' on \
    "$_BOXA_FORGE_GATE"
_boxa::resolve_ssh_gate "$project"
check_eq 'keyed assignment turns the Project SSH gate on' on \
    "$_BOXA_SSH_GATE"
_boxa::ssh_registry_load_project "$project"
check_eq 'assignment installs exactly persona A key paths' "$key_a" \
    "${_BOXA_SSH_REGISTRY_KEYS[*]}"
_boxa::ssh_ensure_project_agent "$project"
persona_agent_pid="$SSH_AGENT_PID"
_boxa::ssh_reapply_registry_keys "$project" >/dev/null 2>&1

_boxa::forge_assign_identity persona-b "$project" >/dev/null
_boxa::resolve_forge_identity "$project"
check_eq 'replacement resolves only persona B' persona-b \
    "$_BOXA_FORGE_RESOLVED_IDENTITY_ID"
_boxa::ssh_registry_load_project "$project"
check_eq 'replacement swaps the complete key set' "$key_b" \
    "${_BOXA_SSH_REGISTRY_KEYS[*]}"
check 'replacement removes every persona A key reference' test \
    "${_BOXA_SSH_REGISTRY_KEYS[*]}" != "$key_a"
expected_b_fingerprint="$(ssh-keygen -lf "$key_b.pub" | awk 'NR == 1 { print $2 }')"
check_eq 'running Project agent immediately holds only persona B key' \
    "$expected_b_fingerprint" \
    "$(ssh-add -l | awk 'NF { print $2 }')"
_boxa::resolve_forge_identity "$project" github
check_eq 'missing GitHub side leaves GitHub unconfigured' '' \
    "$_BOXA_FORGE_RESOLVED_IDENTITY_ID"
_boxa::resolve_forge_identity "$project" gitlab
check_eq 'replacement exposes persona B GitLab side' persona-b \
    "$_BOXA_FORGE_RESOLVED_IDENTITY_ID"
_boxa::forge_load_identity persona-b gitlab
check_eq 'replacement exposes only persona B token' gitlab-b \
    "$_BOXA_FORGE_TOKEN"
check_eq 'replacement exposes persona B GitLab host' gitlab.example \
    "$_BOXA_FORGE_HOST"
_boxa::forge_load_committer_identity persona-b
check_eq 'GitLab-only persona supplies the committer name' bob \
    "$_BOXA_FORGE_COMMITTER_NAME"
check_eq 'GitLab-only persona supplies the committer email' \
    bob@gitlab.example "$_BOXA_FORGE_COMMITTER_EMAIL"
_boxa::forge_load_committer_identity agent
check_eq 'dual-forge persona prefers GitHub committer identity' octocat \
    "$_BOXA_FORGE_COMMITTER_NAME"
check_eq 'GitHub committer uses the noreply host' \
    octocat@users.noreply.github.com "$_BOXA_FORGE_COMMITTER_EMAIL"

assignment_output="$(_boxa::forge_assign_identity token-only "$project")"
check_eq 'keyless assignment explains SSH keys are not forwarded' \
    "Persona 'token-only' assigned to $project; forge access is on; its SSH keys will not be forwarded into this project's ssh-agent (gate off)." \
    "$assignment_output"
_boxa::resolve_ssh_gate "$project"
check_eq 'keyless persona turns the SSH gate off' off "$_BOXA_SSH_GATE"
_boxa::ssh_registry_load_project "$project"
check_eq 'keyless persona clears stale key paths' 0 \
    "${#_BOXA_SSH_REGISTRY_KEYS[@]}"
if ssh-add -l >/dev/null 2>&1; then
    check 'keyless persona immediately empties the running Project agent' false
else
    check_eq 'keyless persona immediately empties the running Project agent' \
        1 "$?"
fi

_boxa::write_forge_conf global '' persona-a identity
_boxa::write_forge_conf global '' on
assignment_output="$(_boxa::forge_assign_identity none "$project")"
check_eq 'cleared assignment explains no persona keys are forwarded' \
    "Persona assignment cleared for $project; forge access is off and no persona SSH keys will be forwarded into this project's ssh-agent (gate off)." \
    "$assignment_output"
_boxa::resolve_forge_gate "$project"
check_eq 'explicit none turns the Project forge gate off' off \
    "$_BOXA_FORGE_GATE"
_boxa::resolve_ssh_gate "$project"
check_eq 'explicit none turns the Project SSH gate off' off \
    "$_BOXA_SSH_GATE"
_boxa::resolve_forge_identity "$project"
check_eq 'explicit none overrides the default persona' '' \
    "$_BOXA_FORGE_RESOLVED_IDENTITY_ID"

late_project=/work/registered-after-default
_boxa::forge_apply_default_persona_to_project "$late_project"
_boxa::ssh_registry_load_project "$late_project"
check_eq 'later Project receives the default persona key set' "$key_a" \
    "${_BOXA_SSH_REGISTRY_KEYS[*]}"
_boxa::resolve_ssh_gate "$late_project"
check_eq 'later Project receives the default persona SSH gate' on \
    "$_BOXA_SSH_GATE"

explicit_off_project=/work/default-with-explicit-ssh-off
printf '\n[%s]\ngate = off\n' "$explicit_off_project" >> "$BOXA_SSH_CONF"
_boxa::forge_apply_default_persona_to_project "$explicit_off_project"
_boxa::resolve_ssh_gate "$explicit_off_project"
check_eq 'late default preserves an explicit Project SSH gate off' project \
    "$_BOXA_SSH_SOURCE"
check_eq 'late default never re-enables an explicitly disabled Project' off \
    "$_BOXA_SSH_GATE"

late_reconcile_calls=0
eval "$(declare -f _boxa::ssh_reconcile_running_project_agent \
    | sed '1s/_boxa::ssh_reconcile_running_project_agent/_boxa::ssh_reconcile_running_project_agent_real/')"
# shellcheck disable=SC2317  # invoked indirectly by the forge materializer
_boxa::ssh_reconcile_running_project_agent() {
    late_reconcile_calls=$((late_reconcile_calls + 1))
}
_boxa::forge_apply_default_persona_to_project "$late_project"
check_eq 'recreating a materialized default skips agent reconciliation' 0 \
    "$late_reconcile_calls"
eval "$(declare -f _boxa::ssh_reconcile_running_project_agent_real \
    | sed '1s/_boxa::ssh_reconcile_running_project_agent_real/_boxa::ssh_reconcile_running_project_agent/')"

failed_late_project=/work/default-reconcile-failure
printf '\n[%s]\ngate = on\n' "$failed_late_project" >> "$BOXA_SSH_CONF"
_boxa::ssh_registry_record_key "$failed_late_project" "$key_b"
before_registry="$(cat "$BOXA_SSH_KEY_REGISTRY")"
reconcile_lock_marker="$_TMPROOT/reconcile-lock-held"
restore_lock_marker="$_TMPROOT/restore-lock-held"
eval "$(declare -f _boxa::ssh_reconcile_running_project_agent \
    | sed '1s/_boxa::ssh_reconcile_running_project_agent/_boxa::ssh_reconcile_running_project_agent_real/')"
eval "$(declare -f _boxa::forge_restore_file \
    | sed '1s/_boxa::forge_restore_file/_boxa::forge_restore_file_real/')"
_boxa::ssh_reconcile_running_project_agent() {
    printf '%s' "${_BOXA_SSH_REGISTRY_LOCK_HELD:-}" \
        > "$reconcile_lock_marker"
    return 1
}
_boxa::forge_restore_file() {
    printf '%s' "${_BOXA_SSH_REGISTRY_LOCK_HELD:-}" > "$restore_lock_marker"
    _boxa::forge_restore_file_real "$@"
}
if _boxa::forge_apply_default_persona_to_project "$failed_late_project" \
        >/dev/null 2>&1; then
    check 'failed late default reconciliation is rejected' false
else
    check 'failed late default reconciliation is rejected' true
fi
check_eq 'failed late default reconciliation rolls back the Key registry' \
    "$before_registry" "$(cat "$BOXA_SSH_KEY_REGISTRY")"
check_eq 'late default reconciliation runs under the Key registry lock' 1 \
    "$(cat "$reconcile_lock_marker")"
check_eq 'late default registry rollback runs under the same lock' 1 \
    "$(cat "$restore_lock_marker")"
eval "$(declare -f _boxa::ssh_reconcile_running_project_agent_real \
    | sed '1s/_boxa::ssh_reconcile_running_project_agent_real/_boxa::ssh_reconcile_running_project_agent/')"
eval "$(declare -f _boxa::forge_restore_file_real \
    | sed '1s/_boxa::forge_restore_file_real/_boxa::forge_restore_file/')"

catalog_lock_marker="$_TMPROOT/catalog-lock.marker"
catalog_lock_release="$_TMPROOT/catalog-lock.release"
hold_catalog_lock() {
    : > "$catalog_lock_marker"
    while [ ! -e "$catalog_lock_release" ]; do sleep 0.01; done
}
_boxa::forge_with_catalog_lock hold_catalog_lock &
catalog_lock_pid=$!
for _ in {1..100}; do
    [ -e "$catalog_lock_marker" ] && break
    sleep 0.01
done
_boxa::forge_apply_default_persona_to_project "$late_project" &
late_default_pid=$!
sleep 0.05
check_eq 'late default materialization waits for the catalog lock' alive \
    "$(kill -0 "$late_default_pid" 2>/dev/null \
        && printf alive || printf '%s' 'done')"
: > "$catalog_lock_release"
wait "$catalog_lock_pid"
wait "$late_default_pid"

_boxa::forge_assign_identity persona-a "$project" >/dev/null

# shellcheck disable=SC2317  # failure injection for the live-agent clear path
ssh-add() {
    if [ "${1:-}" = -D ]; then
        return 1
    fi
    command ssh-add "$@"
}
_BOXA_FORGE_SYNTHESIZED_SSH_GATE=off
if _boxa::forge_reconcile_project_ssh_gate "$project" >/dev/null 2>&1; then
    check 'failed ssh-add -D is propagated by Project reconciliation' false
else
    check 'failed ssh-add -D is propagated by Project reconciliation' true
fi
unset -f ssh-add

forge_off_output="$(_boxa::forge_set_gate project "$project" off)"
_boxa::resolve_forge_identity "$project"
check_eq 'forge off preserves the persona assignment' persona-a \
    "$_BOXA_FORGE_RESOLVED_IDENTITY_ID"
_boxa::resolve_ssh_gate "$project"
check_eq 'forge off turns the synthesized SSH gate off' off \
    "$_BOXA_SSH_GATE"
check 'forge off reports the SSH gate change' grep -q \
    "Project $project SSH forwarding changed from on to off." \
    <<< "$forge_off_output"
_boxa::ssh_registry_load_project "$project"
check_eq 'forge off preserves the assigned SSH registry bundle' "$key_a" \
    "${_BOXA_SSH_REGISTRY_KEYS[*]}"
if ssh-add -l >/dev/null 2>&1; then
    check 'forge off immediately empties the running Project agent' false
else
    check_eq 'forge off immediately empties the running Project agent' 1 "$?"
fi

forge_on_output="$(_boxa::forge_set_gate project "$project" on)"
_boxa::resolve_ssh_gate "$project"
check_eq 'forge on restores the synthesized SSH gate' on "$_BOXA_SSH_GATE"
check 'forge on reports the SSH gate change' grep -q \
    "Project $project SSH forwarding changed from off to on." \
    <<< "$forge_on_output"
check 'forge on summarizes the keyed persona and key count' grep -qF \
    "Project $project SSH forwarding: on (persona 'persona-a', 1 attached key)." \
    <<< "$forge_on_output"
_boxa::ssh_registry_load_project "$project"
check_eq 'forge on restores the same assigned SSH registry bundle' "$key_a" \
    "${_BOXA_SSH_REGISTRY_KEYS[*]}"
expected_a_fingerprint="$(ssh-keygen -lf "$key_a.pub" | awk 'NR == 1 { print $2 }')"
check_eq 'forge on immediately restores the same key in the running Project agent' \
    "$expected_a_fingerprint" "$(ssh-add -l | awk 'NF { print $2 }')"

no_persona_project=/work/forge-on-no-persona
_boxa::write_forge_conf project "$no_persona_project" none identity
no_persona_output="$(_boxa::forge_set_gate project \
    "$no_persona_project" on)"
check 'non-interactive forge on guides unassigned Projects to forge use' \
    grep -qF "Run 'boxa forge use' to assign one." \
    <<< "$no_persona_output"
check 'forge on summarizes the no-persona SSH outcome' grep -qF \
    "Project $no_persona_project SSH forwarding: still off (no persona assigned; run 'boxa forge use')." \
    <<< "$no_persona_output"
_boxa::resolve_ssh_gate "$no_persona_project"
check_eq 'forge on without a persona leaves synthesized SSH off' off \
    "$_BOXA_SSH_GATE"

keyless_project=/work/forge-on-keyless
_boxa::forge_assign_identity token-only "$keyless_project" >/dev/null
_boxa::forge_set_gate project "$keyless_project" off >/dev/null
keyless_output="$(_boxa::forge_set_gate project "$keyless_project" on)"
check 'forge on names its keyless persona and points to forge key attachment' \
    grep -qF \
    "Forge access is on, but persona 'token-only' has no attached SSH keys, so SSH forwarding stays off. Attach keys in 'boxa forge' (Attach an SSH key)." \
    <<< "$keyless_output"
check 'forge on summarizes the keyless-persona SSH outcome' grep -qF \
    "Project $keyless_project SSH forwarding: still off (persona 'token-only' has no attached SSH keys; attach keys in 'boxa forge')." \
    <<< "$keyless_output"
_boxa::resolve_ssh_gate "$keyless_project"
check_eq 'forge on with a keyless persona leaves synthesized SSH off' off \
    "$_BOXA_SSH_GATE"

global_project=/work/global-gate
_boxa::forge_set_gate global '' on >/dev/null
_boxa::forge_apply_default_persona_to_project "$global_project"
_boxa::ssh_ensure_project_agent "$global_project"
_boxa::ssh_reapply_registry_keys "$global_project" >/dev/null 2>&1
global_off_output="$(_boxa::forge_set_gate global '' off)"
_boxa::resolve_forge_gate "$global_project"
check_eq 'global forge off reaches Projects without a Project override' off \
    "$_BOXA_FORGE_GATE"
_boxa::resolve_ssh_gate "$global_project"
check_eq 'global forge off turns an inherited Project SSH gate off' off \
    "$_BOXA_SSH_GATE"
check 'global forge off reports the inherited Project SSH gate change' grep -q \
    "Project $global_project SSH forwarding changed from on to off." \
    <<< "$global_off_output"
_boxa::ssh_registry_load_project "$global_project"
check_eq 'global forge off preserves the inherited Project registry bundle' \
    "$key_a" "${_BOXA_SSH_REGISTRY_KEYS[*]}"
if ssh-add -l >/dev/null 2>&1; then
    check 'global forge off immediately empties the inherited Project agent' false
else
    check_eq 'global forge off immediately empties the inherited Project agent' \
        1 "$?"
fi
_boxa::resolve_forge_gate "$project"
check_eq 'global forge off preserves a Project-level forge override' on \
    "$_BOXA_FORGE_GATE"
_boxa::resolve_ssh_gate "$project"
check_eq 'global forge off preserves its Project-level SSH gate' on \
    "$_BOXA_SSH_GATE"

global_on_output="$(_boxa::forge_set_gate global '' on)"
_boxa::resolve_ssh_gate "$global_project"
check_eq 'global forge on restores the inherited Project SSH gate' on \
    "$_BOXA_SSH_GATE"
check 'global forge on reports the inherited Project SSH gate change' grep -q \
    "Project $global_project SSH forwarding changed from off to on." \
    <<< "$global_on_output"
check_eq 'global forge on immediately restores the inherited Project agent key' \
    "$expected_a_fingerprint" "$(ssh-add -l | awk 'NF { print $2 }')"

global_no_persona_project=/work/global-on-no-persona
global_keyless_project=/work/global-on-keyless
_boxa::write_forge_conf project "$global_no_persona_project" none identity
_boxa::write_forge_conf project "$global_keyless_project" token-only identity
_boxa::forge_apply_project_ssh_gate "$global_no_persona_project" >/dev/null
_boxa::forge_apply_project_ssh_gate "$global_keyless_project" >/dev/null
_boxa::forge_set_gate global '' off >/dev/null
global_still_off_output="$(_boxa::forge_set_gate global '' on)"
check 'global forge on reports an unassigned Project that stays off' grep -qF \
    "Project $global_no_persona_project SSH forwarding: still off (no persona assigned; run 'boxa forge use')." \
    <<< "$global_still_off_output"
check 'global forge on reports a keyless-persona Project that stays off' grep -qF \
    "Project $global_keyless_project SSH forwarding: still off (persona 'token-only' has no attached SSH keys; attach keys in 'boxa forge')." \
    <<< "$global_still_off_output"

failed_global_project=/work/global-reconcile-failure
continued_global_project=/work/global-reconcile-continued
global_reconcile_log="$_TMPROOT/global-reconcile.log"
global_reconcile_failed="$_TMPROOT/global-reconcile.failed"
eval "$(declare -f _boxa::forge_known_project_paths \
    | sed '1s/_boxa::forge_known_project_paths/_boxa::forge_known_project_paths_real/')"
eval "$(declare -f _boxa::forge_reconcile_project_ssh_gate \
    | sed '1s/_boxa::forge_reconcile_project_ssh_gate/_boxa::forge_reconcile_project_ssh_gate_real/')"
_boxa::forge_known_project_paths() {
    printf '%s\n' "$failed_global_project" "$continued_global_project"
}
# shellcheck disable=SC2317  # invoked indirectly by the global gate setter
_boxa::forge_reconcile_project_ssh_gate() {
    printf '%s:%s\n' "$1" "$_BOXA_FORGE_SYNTHESIZED_SSH_GATE" \
        >> "$global_reconcile_log"
    if [ "$1" = "$failed_global_project" ] \
            && [ ! -e "$global_reconcile_failed" ]; then
        : > "$global_reconcile_failed"
        return 1
    fi
}
global_failure_output=
global_failure_rc=0
global_failure_output="$(_boxa::forge_set_gate global '' off 2>&1)" \
    || global_failure_rc=$?
check_eq 'global forge reconciliation propagates a Project failure' 1 \
    "$global_failure_rc"
check 'global forge reconciliation continues after a Project failure' grep -qFx \
    "$continued_global_project:off" "$global_reconcile_log"
check 'global forge reconciliation reports the failed Project' grep -q \
    "$failed_global_project" <<< "$global_failure_output"
_boxa::resolve_forge_gate "$continued_global_project"
check_eq 'failed global forge off leaves the kill switch engaged' off \
    "$_BOXA_FORGE_GATE"
eval "$(declare -f _boxa::forge_known_project_paths_real \
    | sed '1s/_boxa::forge_known_project_paths_real/_boxa::forge_known_project_paths/')"
eval "$(declare -f _boxa::forge_reconcile_project_ssh_gate_real \
    | sed '1s/_boxa::forge_reconcile_project_ssh_gate_real/_boxa::forge_reconcile_project_ssh_gate/')"

rollback_project=/work/forge-on-rollback
_boxa::write_forge_conf project "$rollback_project" persona-a identity
_boxa::write_forge_conf project "$rollback_project" off
_boxa::write_ssh_conf project "$rollback_project" off
rollback_forge_before="$(cat "$BOXA_FORGE_CONF")"
rollback_ssh_before="$(cat "$BOXA_SSH_CONF")"
rollback_reconcile_log="$_TMPROOT/rollback-reconcile.log"
rollback_reconcile_failed="$_TMPROOT/rollback-reconcile.failed"
eval "$(declare -f _boxa::forge_reconcile_project_ssh_gate \
    | sed '1s/_boxa::forge_reconcile_project_ssh_gate/_boxa::forge_reconcile_project_ssh_gate_real/')"
# shellcheck disable=SC2317  # invoked indirectly by the Project gate setter
_boxa::forge_reconcile_project_ssh_gate() {
    printf '%s\n' "$_BOXA_FORGE_SYNTHESIZED_SSH_GATE" \
        >> "$rollback_reconcile_log"
    if [ ! -e "$rollback_reconcile_failed" ]; then
        : > "$rollback_reconcile_failed"
        return 1
    fi
}
rollback_output=
rollback_rc=0
rollback_output="$(_boxa::forge_set_gate project "$rollback_project" on 2>&1)" \
    || rollback_rc=$?
check_eq 'failed forge on exits non-zero' 1 "$rollback_rc"
check_eq 'failed forge on restores forge.conf' "$rollback_forge_before" \
    "$(cat "$BOXA_FORGE_CONF")"
check_eq 'failed forge on restores ssh.conf' "$rollback_ssh_before" \
    "$(cat "$BOXA_SSH_CONF")"
check_eq 'failed forge on reconciles the agent back to off' $'on\noff' \
    "$(cat "$rollback_reconcile_log")"
check 'failed forge on prints the not-applied message' grep -q \
    'Forge access change was not applied; forge access and SSH forwarding were not changed.' \
    <<< "$rollback_output"
eval "$(declare -f _boxa::forge_reconcile_project_ssh_gate_real \
    | sed '1s/_boxa::forge_reconcile_project_ssh_gate_real/_boxa::forge_reconcile_project_ssh_gate/')"

concurrent_registry='[/work/concurrent]'$'\n''key = /tmp/concurrent-key'
eval "$(declare -f _boxa::write_forge_conf \
    | sed '1s/_boxa::write_forge_conf/_boxa::write_forge_conf_real/')"
# shellcheck disable=SC2317  # installed below as a failure-injection stub
_boxa::write_forge_conf_failure() {
    printf '%s\n' "$concurrent_registry" > "$BOXA_SSH_KEY_REGISTRY"
    return 1
}
eval "$(declare -f _boxa::write_forge_conf_failure \
    | sed '1s/_boxa::write_forge_conf_failure/_boxa::write_forge_conf/')"
if _boxa::forge_assign_identity persona-b "$project" >/dev/null 2>&1; then
    check 'failed forge.conf write is rejected' false
else
    check 'failed forge.conf write is rejected' true
fi
check_eq 'failed forge.conf write preserves a concurrent registry change' \
    "$concurrent_registry" "$(cat "$BOXA_SSH_KEY_REGISTRY")"
eval "$(declare -f _boxa::write_forge_conf_real \
    | sed '1s/_boxa::write_forge_conf_real/_boxa::write_forge_conf/')"

before_forge="$(cat "$BOXA_FORGE_CONF")"
before_ssh="$(cat "$BOXA_SSH_CONF")"
before_registry="$(cat "$BOXA_SSH_KEY_REGISTRY")"
eval "$(declare -f _boxa::ssh_registry_replace_project \
    | sed '1s/_boxa::ssh_registry_replace_project/_boxa::ssh_registry_replace_project_real/')"
_boxa::ssh_registry_replace_project() { return 1; }
if _boxa::forge_assign_identity persona-b "$project" >/dev/null 2>&1; then
    check 'failed bundle write is rejected' false
else
    check 'failed bundle write is rejected' true
fi
check_eq 'failed bundle write rolls back forge.conf' "$before_forge" \
    "$(cat "$BOXA_FORGE_CONF")"
check_eq 'failed bundle write rolls back ssh.conf' "$before_ssh" \
    "$(cat "$BOXA_SSH_CONF")"
check_eq 'failed bundle write rolls back the Key registry' "$before_registry" \
    "$(cat "$BOXA_SSH_KEY_REGISTRY")"
eval "$(declare -f _boxa::ssh_registry_replace_project_real \
    | sed '1s/_boxa::ssh_registry_replace_project_real/_boxa::ssh_registry_replace_project/')"

_boxa::write_forge_conf global '' persona-b identity
_boxa::forge_assign_identity persona-b "$project" >/dev/null
if _boxa::forge_remove persona-b false >/dev/null 2>&1; then
    check 'guarded remove refuses an assigned/default persona' false
else
    check 'guarded remove refuses an assigned/default persona' true
fi
_boxa::forge_remove persona-b true >/dev/null
check 'forced remove deletes the split token file' test ! -e \
    "$BOXA_FORGE_DIR/tokens/persona-b.gitlab"
_boxa::resolve_forge_gate "$project"
check_eq 'forced remove clears the Project assignment' '' \
    "$_BOXA_FORGE_PROJECT_IDENTITY"
check_eq 'forced remove clears the default persona' '' \
    "$_BOXA_FORGE_GLOBAL_IDENTITY"
_boxa::resolve_ssh_gate "$project"
check_eq 'forced remove turns stale SSH forwarding off' off \
    "$_BOXA_SSH_GATE"
_boxa::ssh_registry_load_project "$project"
check_eq 'forced remove clears stale Project key paths' 0 \
    "${#_BOXA_SSH_REGISTRY_KEYS[@]}"

status_output="$(_boxa::forge_status "$project")"
check 'status reports the effective forge gate' grep -q \
    'Forge access: on' <<< "$status_output"
check 'status reports the effective SSH gate' grep -q \
    'SSH forwarding: off' <<< "$status_output"
check 'status reports no resolved persona after forced cleanup' grep -q \
    'Resolved persona: none' <<< "$status_output"

printf '%s passed, %s failed\n' "$pass_count" "$fail_count"
[ "$fail_count" -eq 0 ]
