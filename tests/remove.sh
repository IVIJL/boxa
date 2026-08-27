#!/bin/bash
# Plain-bash integration assertions for `boxa remove` Project-state cleanup.
# Usage: bash tests/remove.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
_TMPROOT="$(mktemp -d)"
trap 'rm -rf "$_TMPROOT"' EXIT

TEST_BOXA_DIR="$_TMPROOT/boxa"
TEST_HOME="$_TMPROOT/home"
TEST_CONFIG="$TEST_HOME/.config/boxa"
mkdir -p "$TEST_BOXA_DIR" "$_TMPROOT/bin" "$TEST_CONFIG"
cp "$SCRIPT_DIR/../docker-run.sh" "$TEST_BOXA_DIR/docker-run.sh"
cp -R "$SCRIPT_DIR/../lib" "$TEST_BOXA_DIR/lib"
cp -R "$SCRIPT_DIR/../config" "$TEST_BOXA_DIR/config"

cat > "$_TMPROOT/bin/docker" <<'STUB'
#!/bin/bash
case "${1:-}" in
    volume)
        case "${2:-}" in
            ls) [ ! -f "$BOXA_REMOVE_TEST_VOLUMES" ] || cat "$BOXA_REMOVE_TEST_VOLUMES" ;;
            inspect)
                grep -qxF -- "${3:-}" "$BOXA_REMOVE_TEST_VOLUMES" 2>/dev/null
                ;;
            rm)
                volume="${3:-}"
                printf '%s\n' "$volume" >> "$BOXA_REMOVE_TEST_REMOVED_VOLUMES"
                grep -vxF -- "$volume" "$BOXA_REMOVE_TEST_VOLUMES" \
                    > "$BOXA_REMOVE_TEST_VOLUMES.tmp" || true
                mv "$BOXA_REMOVE_TEST_VOLUMES.tmp" "$BOXA_REMOVE_TEST_VOLUMES"
                ;;
        esac
        ;;
    ps)
        if [ -n "${BOXA_REMOVE_TEST_RUNNING:-}" ] \
                && [[ " $* " == *" name=^boxa-${BOXA_REMOVE_TEST_RUNNING}$ "* ]]; then
            printf '%s\n' running-id
        fi
        ;;
esac
STUB

cat > "$_TMPROOT/bin/sudo" <<'STUB'
#!/bin/bash
exit 0
STUB

cat > "$_TMPROOT/bin/flock" <<'STUB'
#!/bin/bash
if [ -d "$BOXA_REMOVE_TEST_FORGE_LOCK" ] \
        && [ -d "$BOXA_REMOVE_TEST_SSH_LOCK" ]; then
    printf 'held\n' >> "$BOXA_REMOVE_TEST_PROJECT_LOCK_ORDER"
else
    printf 'released\n' >> "$BOXA_REMOVE_TEST_PROJECT_LOCK_ORDER"
fi
if [ -n "${BOXA_REMOVE_TEST_REGISTER_ON_LOCK:-}" ]; then
    jq -n --arg path "$BOXA_REMOVE_TEST_REGISTER_ON_LOCK" \
        '{version: 1, projects: {
            ($path): {name: "registered-under-lock", lastSeen: "now"}
        }}' > "$BOXA_REMOVE_TEST_PROJECTS"
fi
STUB
chmod +x "$TEST_BOXA_DIR/docker-run.sh" "$_TMPROOT/bin/docker" \
    "$_TMPROOT/bin/flock" "$_TMPROOT/bin/sudo"

export BOXA_REMOVE_TEST_VOLUMES="$_TMPROOT/volumes"
export BOXA_REMOVE_TEST_REMOVED_VOLUMES="$_TMPROOT/removed-volumes"
export BOXA_REMOVE_TEST_FORGE_LOCK="$TEST_CONFIG/forge.conf.lock"
export BOXA_REMOVE_TEST_SSH_LOCK="$TEST_CONFIG/ssh-key-registry.lock"
export BOXA_REMOVE_TEST_PROJECT_LOCK_ORDER="$_TMPROOT/project-lock-order"
export BOXA_REMOVE_TEST_PROJECTS="$TEST_CONFIG/projects.json"

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

assert_file_eq() {
    local label="$1" expected="$2" actual="$3"
    if cmp -s "$expected" "$actual"; then
        printf 'PASS  %s\n' "$label"
    else
        printf 'FAIL  %s\n' "$label"
        fail_count=$((fail_count + 1))
    fi
}

run_boxa() {
    HOME="$TEST_HOME" XDG_CONFIG_HOME="$TEST_HOME/.config" \
        PATH="$_TMPROOT/bin:$PATH" BOXA_PICKER_FZF=0 \
        bash "$TEST_BOXA_DIR/docker-run.sh" "$@"
}

reset_stores() {
    rm -rf "$TEST_CONFIG"
    mkdir -p "$TEST_CONFIG"
    : > "$BOXA_REMOVE_TEST_VOLUMES"
    : > "$BOXA_REMOVE_TEST_REMOVED_VOLUMES"
    : > "$BOXA_REMOVE_TEST_PROJECT_LOCK_ORDER"
    unset BOXA_REMOVE_TEST_RUNNING
    unset BOXA_REMOVE_TEST_REGISTER_ON_LOCK
}

write_projects() {
    local body="$1"
    printf '{"version":1,"projects":%s}\n' "$body" \
        > "$TEST_CONFIG/projects.json"
}

# Config-only removal purges all four stores while preserving unrelated bytes.
reset_stores
target=/work/remove-me
other=/work/keep-me
write_projects '{"/work/remove-me":{"name":"remove-me","lastSeen":"now"},"/work/keep-me":{"name":"keep-me","lastSeen":"then"}}'
cat > "$TEST_CONFIG/forge.conf" <<EOF
# global forge bytes
forge = off

[$target]
# target comment
forge = on
identity = alpha

[$other]
  forge = off # keep formatting
EOF
cat > "$TEST_CONFIG/ssh.conf" <<EOF
gate = off

[$target]
gate = on

[$other]
  gate = off # keep formatting
EOF
cat > "$TEST_CONFIG/ssh-key-registry" <<EOF
[$target]
key = /keys/remove

[$other]
# unrelated registry bytes
key = /keys/keep
EOF
cat > "$_TMPROOT/expected-forge" <<EOF
# global forge bytes
forge = off

[$other]
  forge = off # keep formatting
EOF
cat > "$_TMPROOT/expected-ssh" <<EOF
gate = off

[$other]
  gate = off # keep formatting
EOF
cat > "$_TMPROOT/expected-registry" <<EOF
[$other]
# unrelated registry bytes
key = /keys/keep
EOF
output="$(run_boxa remove remove-me 2>&1)"
rc=$?
assert_eq "config-only Project succeeds without volumes" 0 "$rc"
assert_contains "missing volumes are a note" \
    "Note: no volumes for project remove-me." "$output"
assert_eq "projects.json drops only the target path" \
    'keep-me' "$(jq -r '.projects | keys[] as $path | .[$path].name' \
        "$TEST_CONFIG/projects.json")"
assert_file_eq "forge purge preserves unrelated bytes" \
    "$_TMPROOT/expected-forge" "$TEST_CONFIG/forge.conf"
assert_file_eq "SSH purge preserves unrelated bytes" \
    "$_TMPROOT/expected-ssh" "$TEST_CONFIG/ssh.conf"
assert_file_eq "registry purge preserves unrelated bytes" \
    "$_TMPROOT/expected-registry" "$TEST_CONFIG/ssh-key-registry"
assert_eq "projects.json mutates while forge and SSH locks are held" held \
    "$(cat "$BOXA_REMOVE_TEST_PROJECT_LOCK_ORDER")"

# The missing-registry decision is made after acquiring all purge locks.
reset_stores
lock_publish_path=/work/published-at-lock
printf '[%s]\nforge = on\n' "$lock_publish_path" > "$TEST_CONFIG/forge.conf"
export BOXA_REMOVE_TEST_REGISTER_ON_LOCK="$lock_publish_path"
lock_publish_output="$(run_boxa remove "$lock_publish_path" 2>&1)"
lock_publish_rc=$?
unset BOXA_REMOVE_TEST_REGISTER_ON_LOCK
assert_eq "registry published at lock acquisition is removed" 0 "$lock_publish_rc"
assert_contains "lock-time registration is reported as removed" \
    "Removed projects.json entry: $lock_publish_path" "$lock_publish_output"
assert_eq "lock-time registration leaves no registry entry" 0 \
    "$(jq '.projects | length' "$TEST_CONFIG/projects.json")"

# JSON registry rows preserve tabs and backslashes through name resolution.
reset_stores
special_path=$'/work/back\\slash\tsegment'
jq -n --arg path "$special_path" --arg name special-name \
    '{version: 1, projects: {($path): {name: $name, lastSeen: "now"}}}' \
    > "$TEST_CONFIG/projects.json"
printf '[%s]\nforge = on\n' "$special_path" > "$TEST_CONFIG/forge.conf"
run_boxa remove special-name >/dev/null 2>&1
special_rc=$?
assert_eq "registry path with tab and backslash resolves exactly" 0 "$special_rc"
assert_eq "special-character registry path is purged" 0 \
    "$(jq '.projects | length' "$TEST_CONFIG/projects.json")"
assert_eq "special-character config section is purged" 0 \
    "$(wc -c < "$TEST_CONFIG/forge.conf" | tr -d ' ')"

# projects.json-only paths are not constrained by the SSH registry grammar.
reset_stores
hash_path='/work/hash#project'
jq -n --arg path "$hash_path" --arg name hash-project \
    '{version: 1, projects: {($path): {name: $name, lastSeen: "now"}}}' \
    > "$TEST_CONFIG/projects.json"
run_boxa remove hash-project >/dev/null 2>&1
hash_rc=$?
assert_eq "projects.json-only path containing # is removable" 0 "$hash_rc"
assert_eq "# path is removed from projects.json" 0 \
    "$(jq '.projects | length' "$TEST_CONFIG/projects.json")"

# Encoded path tokens keep LF-containing paths as one removal target.
reset_stores
lf_path=$'/work/line\n/work/unrelated'
unrelated_path=/work/unrelated
jq -n --arg target "$lf_path" --arg unrelated "$unrelated_path" \
    '{version: 1, projects: {
        ($target): {name: "line-break", lastSeen: "now"},
        ($unrelated): {name: "keep-unrelated", lastSeen: "now"}
    }}' > "$TEST_CONFIG/projects.json"
run_boxa remove line-break >/dev/null 2>&1
lf_rc=$?
assert_eq "LF-containing path remains one purge target" 0 "$lf_rc"
assert_eq "LF purge preserves the separately keyed path" "$unrelated_path" \
    "$(jq -r '.projects | keys[]' "$TEST_CONFIG/projects.json")"

# An absolute path uses its registered name for legacy artifact cleanup.
reset_stores
path_target=/work/path-target
write_projects '{"/work/path-target":{"name":"mapped-name","lastSeen":"now"}}'
printf '%s\n' boxa-mapped-name-history > "$BOXA_REMOVE_TEST_VOLUMES"
path_output="$(run_boxa remove "$path_target" 2>&1)"
path_rc=$?
assert_eq "absolute path target succeeds" 0 "$path_rc"
assert_contains "path target reports mapped Project name" \
    "Removing data for project: mapped-name" "$path_output"
assert_eq "path target removes mapped-name volumes" boxa-mapped-name-history \
    "$(cat "$BOXA_REMOVE_TEST_REMOVED_VOLUMES")"

# Legacy literal volume cleanup still resolves the sanitized registry name.
reset_stores
write_projects '{"/work/legacy":{"name":"legacy-name","lastSeen":"now"}}'
printf '%s\n' boxa-legacy.name-history > "$BOXA_REMOVE_TEST_VOLUMES"
legacy_output="$(run_boxa remove legacy.name 2>&1)"
legacy_rc=$?
assert_eq "legacy literal volume target succeeds" 0 "$legacy_rc"
assert_contains "legacy literal volume is still removed" \
    "Removed volume: boxa-legacy.name-history" "$legacy_output"
assert_eq "legacy target also purges its sanitized registry mapping" 0 \
    "$(jq '.projects | length' "$TEST_CONFIG/projects.json")"

# Every literal/sanitized name is guarded before legacy cleanup starts.
reset_stores
write_projects '{"/work/legacy-running":{"name":"legacy-running","lastSeen":"now"}}'
printf '%s\n' boxa-legacy.running-history > "$BOXA_REMOVE_TEST_VOLUMES"
export BOXA_REMOVE_TEST_RUNNING=legacy-running
running_output="$(run_boxa remove legacy.running 2>&1)"
running_rc=$?
assert_eq "sanitized running Container blocks legacy removal" 1 "$running_rc"
assert_contains "running guard names the sanitized Container" \
    "Container boxa-legacy-running is running" "$running_output"
assert_eq "blocked legacy removal preserves its volume" \
    boxa-legacy.running-history "$(cat "$BOXA_REMOVE_TEST_VOLUMES")"
assert_eq "blocked legacy removal preserves its registry path" 1 \
    "$(jq '.projects | length' "$TEST_CONFIG/projects.json")"

# Malformed SSH registry data fails loudly before any config rewrite.
reset_stores
malformed_path=/work/malformed-registry
write_projects '{"/work/malformed-registry":{"name":"malformed-registry","lastSeen":"now"}}'
printf '[%s]\ngate = on\n' "$malformed_path" > "$TEST_CONFIG/ssh.conf"
printf '[%s]\nkey = /keys/valid\ngarbage\n' "$malformed_path" \
    > "$TEST_CONFIG/ssh-key-registry"
printf '%s\n' boxa-malformed-registry-history > "$BOXA_REMOVE_TEST_VOLUMES"
malformed_output="$(run_boxa remove malformed-registry 2>&1)"
malformed_rc=$?
assert_eq "malformed SSH registry fails outer remove loudly" 1 "$malformed_rc"
assert_contains "malformed registry reports preflight failure" \
    "ERROR: invalid path-keyed state prevents removal" "$malformed_output"
assert_eq "malformed registry preflight preserves Project volumes" \
    boxa-malformed-registry-history "$(cat "$BOXA_REMOVE_TEST_VOLUMES")"
assert_eq "malformed registry preflight removes no Project volumes" '' \
    "$(cat "$BOXA_REMOVE_TEST_REMOVED_VOLUMES")"
assert_contains "failed malformed purge preserves ssh.conf" \
    "[$malformed_path]" "$(cat "$TEST_CONFIG/ssh.conf")"
assert_eq "failed malformed purge preserves projects.json" 1 \
    "$(jq '.projects | length' "$TEST_CONFIG/projects.json")"

# Malformed projects.json fails before any path-keyed or artifact mutation.
reset_stores
malformed_projects_path=/work/malformed-projects
printf '{"version":1,"projects":' > "$TEST_CONFIG/projects.json"
cp "$TEST_CONFIG/projects.json" "$_TMPROOT/expected-malformed-projects"
printf '[%s]\nforge = on\n' "$malformed_projects_path" \
    > "$TEST_CONFIG/forge.conf"
printf '[%s]\ngate = on\n' "$malformed_projects_path" \
    > "$TEST_CONFIG/ssh.conf"
printf '[%s]\nkey = /keys/keep\n' "$malformed_projects_path" \
    > "$TEST_CONFIG/ssh-key-registry"
cp "$TEST_CONFIG/forge.conf" "$_TMPROOT/expected-malformed-projects-forge"
cp "$TEST_CONFIG/ssh.conf" "$_TMPROOT/expected-malformed-projects-ssh"
cp "$TEST_CONFIG/ssh-key-registry" \
    "$_TMPROOT/expected-malformed-projects-registry"
printf '%s\n' boxa-malformed-projects-history > "$BOXA_REMOVE_TEST_VOLUMES"
malformed_projects_output="$(run_boxa remove "$malformed_projects_path" 2>&1)"
malformed_projects_rc=$?
assert_eq "malformed projects.json fails outer remove loudly" 1 \
    "$malformed_projects_rc"
assert_contains "malformed projects.json reports preflight failure" \
    "ERROR: malformed or unsupported projects.json; removal aborted." \
    "$malformed_projects_output"
assert_eq "malformed projects.json preserves Project volumes" \
    boxa-malformed-projects-history "$(cat "$BOXA_REMOVE_TEST_VOLUMES")"
assert_eq "malformed projects.json removes no Project volumes" '' \
    "$(cat "$BOXA_REMOVE_TEST_REMOVED_VOLUMES")"
assert_file_eq "malformed projects.json preserves forge.conf" \
    "$_TMPROOT/expected-malformed-projects-forge" "$TEST_CONFIG/forge.conf"
assert_file_eq "malformed projects.json preserves ssh.conf" \
    "$_TMPROOT/expected-malformed-projects-ssh" "$TEST_CONFIG/ssh.conf"
assert_file_eq "malformed projects.json preserves SSH key registry" \
    "$_TMPROOT/expected-malformed-projects-registry" \
    "$TEST_CONFIG/ssh-key-registry"
assert_file_eq "malformed projects.json remains byte-identical" \
    "$_TMPROOT/expected-malformed-projects" "$TEST_CONFIG/projects.json"

# Missing and valid-empty Project registries remain non-errors.
reset_stores
absent_projects_path=/work/absent-projects
printf '[%s]\nforge = on\n' "$absent_projects_path" \
    > "$TEST_CONFIG/forge.conf"
absent_projects_output="$(run_boxa remove "$absent_projects_path" 2>&1)"
absent_projects_rc=$?
assert_eq "absent projects.json still permits removal" 0 "$absent_projects_rc"
assert_contains "absent projects.json is reported as a note" \
    "Note: no projects.json entry for $absent_projects_path." \
    "$absent_projects_output"

reset_stores
empty_projects_path=/work/empty-projects
write_projects '{}'
printf '[%s]\nforge = on\n' "$empty_projects_path" \
    > "$TEST_CONFIG/forge.conf"
empty_projects_output="$(run_boxa remove "$empty_projects_path" 2>&1)"
empty_projects_rc=$?
assert_eq "valid-empty projects.json still permits removal" 0 \
    "$empty_projects_rc"
assert_contains "valid-empty projects.json is reported as a note" \
    "Note: no projects.json entry for $empty_projects_path." \
    "$empty_projects_output"

# The interactive union exposes a registry-only Project.
reset_stores
write_projects '{"/work/picker-only":{"name":"picker-only","lastSeen":"now"}}'
picker_output="$(BOXA_PICKER_TEST_CHOICE=1 run_boxa remove 2>&1)"
picker_rc=$?
assert_eq "picker selects a config-only Project" 0 "$picker_rc"
assert_contains "picker union lists the config-only name" picker-only "$picker_output"
assert_eq "picker selection purges its registry entry" 0 \
    "$(jq '.projects | length' "$TEST_CONFIG/projects.json")"

# "Remove all" covers both sides of the picker union.
reset_stores
write_projects '{"/work/all-config":{"name":"all-config","lastSeen":"now"}}'
printf '%s\n' boxa-all-volume-history > "$BOXA_REMOVE_TEST_VOLUMES"
all_output="$(BOXA_PICKER_TEST_CHOICE=a run_boxa remove 2>&1)"
all_rc=$?
assert_eq "Remove all succeeds for mixed Project stores" 0 "$all_rc"
assert_contains "Remove all processes the volume-backed Project" \
    "Removing data for project: all-volume" "$all_output"
assert_contains "Remove all processes the config-only Project" \
    "Removing data for project: all-config" "$all_output"
assert_eq "Remove all purges the config-only registry entry" 0 \
    "$(jq '.projects | length' "$TEST_CONFIG/projects.json")"
assert_eq "Remove all removes the volume-backed Project volume" \
    boxa-all-volume-history "$(cat "$BOXA_REMOVE_TEST_REMOVED_VOLUMES")"

# A key-registry-only orphan appears by path and is removable from the picker.
reset_stores
orphan=/work/registry-orphan
printf '[%s]\nkey = /keys/orphan\n' "$orphan" \
    > "$TEST_CONFIG/ssh-key-registry"
orphan_output="$(BOXA_PICKER_TEST_CHOICE=1 run_boxa remove 2>&1)"
orphan_rc=$?
assert_eq "picker selects an unregistered registry path" 0 "$orphan_rc"
assert_contains "orphan picker row is shown by path" "$orphan" "$orphan_output"
assert_eq "orphan registry section is purged" 0 \
    "$(wc -c < "$TEST_CONFIG/ssh-key-registry" | tr -d ' ')"

# Ambiguous names prompt and purge only the explicitly selected path.
reset_stores
write_projects '{"/work/ambiguous-a":{"name":"ambiguous","lastSeen":"a"},"/work/ambiguous-b":{"name":"ambiguous","lastSeen":"b"}}'
printf '[/work/ambiguous-a]\nforge = on\n\n[/work/ambiguous-b]\nforge = off\n' \
    > "$TEST_CONFIG/forge.conf"
ambiguous_output="$(BOXA_PICKER_TEST_CHOICE=2 \
    run_boxa remove ambiguous 2>&1)"
ambiguous_rc=$?
assert_eq "ambiguous name selection succeeds" 0 "$ambiguous_rc"
assert_contains "ambiguous name lists the path picker" \
    "Purge Project path:" "$ambiguous_output"
assert_eq "ambiguous selection keeps the unselected registry path" \
    '/work/ambiguous-a' "$(jq -r '.projects | keys[]' \
        "$TEST_CONFIG/projects.json")"
assert_contains "ambiguous selection keeps the unselected forge section" \
    '[/work/ambiguous-a]' "$(cat "$TEST_CONFIG/forge.conf")"

# Only a target absent from every store fails.
reset_stores
missing_output="$(run_boxa remove nowhere 2>&1)"
missing_rc=$?
assert_eq "target absent everywhere exits non-zero" 1 "$missing_rc"
assert_contains "absent target reports nothing to remove" \
    "nothing to remove for nowhere" "$missing_output"

if [ "$fail_count" -gt 0 ]; then
    printf '\n%d test(s) failed.\n' "$fail_count"
    exit 1
fi

printf '\nAll remove tests passed.\n'
