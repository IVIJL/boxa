#!/bin/bash
# Pure mapping coverage plus migration classification. The ownership walk is
# exercised only when this test is root because fake high-UID owners require
# chown authority; non-root runs report that limitation explicitly.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOXA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
_TMPROOT="$(mktemp -d)"
trap 'rm -rf "$_TMPROOT"' EXIT

# The test computes BOXA_DIR at runtime, which ShellCheck cannot resolve.
# shellcheck disable=SC1091
source "$BOXA_DIR/lib/subid.sh"

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

assert_mapping() {
    local uid="$1" output first_start first_count second_start second_count
    local total

    output=$(boxa_generate_subid_ranges "$uid" node)
    IFS=: read -r _ first_start first_count <<< "$(sed -n '1p' <<< "$output")"
    IFS=: read -r _ second_start second_count <<< "$(sed -n '2p' <<< "$output")"
    total=$((first_count + second_count))
    assert_eq "U=$uid ranges sum to 65535" 65535 "$total"
    assert_eq "U=$uid first range starts at 1" 1 "$first_start"
    assert_eq "U=$uid first range ends below the hole" "$((uid - 1))" \
        "$((first_start + first_count - 1))"
    assert_eq "U=$uid second range starts above the hole" "$((uid + 1))" \
        "$second_start"
    assert_eq "U=$uid second range excludes uid 0" 1 \
        "$((second_start > 0))"
    assert_eq "U=$uid second range excludes the hole" 1 \
        "$((second_start > uid))"
}

for uid in 1000 501 65000; do
    assert_mapping "$uid"
done

assert_eq "U=1 skips the zero-length first range" "node:2:65535" \
    "$(boxa_generate_subid_ranges 1 node)"

assert_eq "U at the budget limit keeps one identity range below the hole" \
    "node:1:65535" "$(boxa_generate_subid_ranges 65536 node)"
assert_eq "U above the budget limit keeps one identity range below the hole" \
    "node:1:65535" "$(boxa_generate_subid_ranges 70000 node)"

data_root="$_TMPROOT/docker"
mapping=$(boxa_subid_mapping_id 1000)
assert_eq "absent data-root is empty" empty \
    "$(boxa_subid_data_root_state "$data_root" "$mapping")"
mkdir -p "$data_root"
assert_eq "empty data-root is empty" empty \
    "$(boxa_subid_data_root_state "$data_root" "$mapping")"
mkdir "$data_root/overlay2"
assert_eq "unstamped populated data-root is legacy" legacy \
    "$(boxa_subid_data_root_state "$data_root" "$mapping")"
printf '%s\n' wrong > "$data_root/$BOXA_SUBID_STAMP_NAME"
assert_eq "wrong stamp is incompatible" incompatible \
    "$(boxa_subid_data_root_state "$data_root" "$mapping")"
printf '%s\n' "$mapping" > "$data_root/$BOXA_SUBID_STAMP_NAME"
assert_eq "matching stamp is current" current \
    "$(boxa_subid_data_root_state "$data_root" "$mapping")"

assert_eq "old uid below U becomes identity mapped" 70 \
    "$(boxa_old_subid_to_new 100069 1000)"
assert_eq "old uid at U moves above the hole" 1001 \
    "$(boxa_old_subid_to_new 100999 1000)"

if [ "$(id -u)" = "0" ]; then
    remap_root="$_TMPROOT/remap"
    mkdir -p "$remap_root"
    touch "$remap_root/identity" "$remap_root/shifted"
    chown 100069:100069 "$remap_root/identity"
    chown 100999:100999 "$remap_root/shifted"
    boxa_migrate_legacy_subids "$remap_root" 1000
    assert_eq "real remap applies identity owner" 70:70 \
        "$(stat -c '%u:%g' "$remap_root/identity")"
    assert_eq "real remap applies above-hole shift" 1001:1001 \
        "$(stat -c '%u:%g' "$remap_root/shifted")"
    touch "$remap_root/untouched"
    chown 100069:100069 "$remap_root/untouched"
    mkdir "$remap_root/refused"
    touch "$remap_root/refused/edge"
    chown 165535:165535 "$remap_root/refused/edge"
    if boxa_migrate_legacy_subids "$remap_root" 1000 2>/dev/null; then
        printf 'FAIL  unrepresentable owner 165535 is refused\n'
        fail_count=$((fail_count + 1))
    else
        printf 'PASS  unrepresentable owner 165535 is refused\n'
    fi
    assert_eq "refused migration changes nothing" 100069:100069 \
        "$(stat -c '%u:%g' "$remap_root/untouched")"
    printf 'PASS  Real ownership remap exercised (test is root).\n'
else
    printf 'PASS  Real ownership remap not exercised: non-root test; detection/decision and arithmetic only.\n'
fi

printf '\n'
if [ "$fail_count" -eq 0 ]; then
    echo "All subid mapping assertions passed."
else
    echo "$fail_count assertion(s) failed."
    exit 1
fi
