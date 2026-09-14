#!/bin/bash
# Classifier and decision-path coverage runs everywhere. Real owner changes
# require root and are skipped explicitly otherwise; injected uid/gid values
# keep warn-mode coverage meaningful without privileged fixture setup.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOXA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
_TMPROOT="$(mktemp -d)"
trap 'rm -rf "$_TMPROOT"' EXIT

# The test computes BOXA_DIR at runtime, which ShellCheck cannot resolve.
# shellcheck disable=SC1091
source "$BOXA_DIR/lib/ownership.sh"

fail_count=0
pass_count=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        printf 'PASS  %s\n' "$label"
        pass_count=$((pass_count + 1))
    else
        printf 'FAIL  %s\n      expected: %q\n      actual:   %q\n' \
            "$label" "$expected" "$actual"
        fail_count=$((fail_count + 1))
    fi
}

assert_true() {
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

assert_false() {
    local label="$1"
    shift
    if "$@"; then
        printf 'FAIL  %s\n' "$label"
        fail_count=$((fail_count + 1))
    else
        printf 'PASS  %s\n' "$label"
        pass_count=$((pass_count + 1))
    fi
}

assert_eq "root uid is repairable" fix-root \
    "$(boxa_ownership_classify 0 1000 1000)"
assert_eq "Container uid is OK" ok \
    "$(boxa_ownership_classify 1000 1000 1000)"
assert_eq "identity-mapped uid 70 is OK" ok \
    "$(boxa_ownership_classify 70 70 1000)"
assert_eq "legacy uid 100069 needs remap" fix-old-mapping \
    "$(boxa_ownership_classify 100069 100069 1000)"
assert_eq "nobody uid 65534 warns" warn \
    "$(boxa_ownership_classify 65534 65534 1000)"
assert_eq "host uid 65536 (inner 65535 above the hole) is ok" ok \
    "$(boxa_ownership_classify 65536 65536 1000)"
assert_eq "host uid 65537 warns" warn \
    "$(boxa_ownership_classify 65537 65537 1000)"
assert_eq "U inside the old-map range is ok, not old-mapping" ok \
    "$(boxa_ownership_classify 100500 100500 100500)"
assert_eq "old-map owner is still remapped when U is in the old range" fix-old-mapping \
    "$(boxa_ownership_classify 100069 100069 100500)"
assert_eq "host uid 65536 warns when U is above the budget" warn \
    "$(boxa_ownership_classify 65536 65536 70000)"
assert_eq "U above the budget is ok" ok \
    "$(boxa_ownership_classify 70000 70000 70000)"
assert_eq "old-map remap keeps a U component inside the old range" 100500 \
    "$(_boxa_ownership_remap_old_id 100500 100500)"
assert_eq "old-map remap still converts the peer old id" 70 \
    "$(_boxa_ownership_remap_old_id 100069 100500)"
assert_eq "old-map remap leaves an identity id alone" 70 \
    "$(_boxa_ownership_remap_old_id 70 1000)"
assert_eq "root gid is repairable" fix-root \
    "$(boxa_ownership_classify 1000 0 1000)"

config_file="$_TMPROOT/ownership.conf"
assert_eq "missing config defaults to auto" auto \
    "$(ownership_config_read "$config_file")"
ownership_config_write "$config_file" warn
assert_eq "written warn config is read" warn \
    "$(ownership_config_read "$config_file")"
printf 'ownership_fix=invalid\n' > "$config_file"
assert_false "invalid config is rejected" ownership_config_read "$config_file"

project_root="$_TMPROOT/project"
outside_root="$_TMPROOT/outside"
mkdir -p "$project_root/subdir" "$outside_root"
ln -s "$outside_root" "$project_root/escape"
assert_true "path below Project root is accepted" \
    boxa_ownership_path_within_root "$project_root" "$project_root/subdir"
assert_false "outside path is refused" \
    boxa_ownership_path_within_root "$project_root" "$outside_root"
assert_false "symlink escape is refused" \
    boxa_ownership_path_within_root "$project_root" "$project_root/escape"

warn_fixture="$project_root/warn-fixture"
touch "$warn_fixture"
warn_owner_before=$(stat -c '%u:%g' "$warn_fixture")
warn_mtime_before=$(stat -c '%Y' "$warn_fixture")
warn_output=""
warn_rc=0
warn_output=$(boxa_ownership_process_hit warn doctor "$warn_fixture" 1000 0 0) || \
    warn_rc=$?
assert_eq "warn decision reports action needed" 3 "$warn_rc"
assert_eq "warn decision leaves owner unchanged" "$warn_owner_before" \
    "$(stat -c '%u:%g' "$warn_fixture")"
assert_eq "warn decision leaves mtime unchanged" "$warn_mtime_before" \
    "$(stat -c '%Y' "$warn_fixture")"
assert_true "warn decision names the hit" grep -q 'Ownership action needed' \
    <<< "$warn_output"

if [ "$(id -u)" = "0" ]; then
    real_root="$_TMPROOT/real"
    mkdir -p "$real_root/root-tree" "$real_root/old-tree"
    touch "$real_root/root-tree/file" "$real_root/old-tree/file"
    chown 1000:1000 "$real_root"
    chown -R 0:0 "$real_root/root-tree"
    chown -R 100069:100069 "$real_root/old-tree"
    boxa_ownership_run "$real_root" 1000 auto unlimited doctor >/dev/null
    assert_eq "real root tree is repaired to U" 1000:1000 \
        "$(stat -c '%u:%g' "$real_root/root-tree")"
    assert_eq "real old tree is remapped to uid 70" 70:70 \
        "$(stat -c '%u:%g' "$real_root/old-tree")"
    second_output=$(boxa_ownership_run "$real_root" 1000 auto unlimited doctor)
    assert_true "second real repair is a no-op" grep -q '0 hit(s)' \
        <<< "$second_output"
    printf 'PASS  Real ownership repair exercised (test is root).\n'
    pass_count=$((pass_count + 1))
else
    printf 'PASS  Real ownership repair not exercised: non-root test; classifier and injected decision path only.\n'
    pass_count=$((pass_count + 1))
fi

printf '\n%s PASS, %s FAIL\n' "$pass_count" "$fail_count"
if [ "$fail_count" -ne 0 ]; then
    exit 1
fi
