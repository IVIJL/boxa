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
    ps) ;;
esac
STUB

cat > "$_TMPROOT/bin/sudo" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$TEST_BOXA_DIR/docker-run.sh" "$_TMPROOT/bin/docker" \
    "$_TMPROOT/bin/sudo"

export BOXA_REMOVE_TEST_VOLUMES="$_TMPROOT/volumes"
export BOXA_REMOVE_TEST_REMOVED_VOLUMES="$_TMPROOT/removed-volumes"

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
