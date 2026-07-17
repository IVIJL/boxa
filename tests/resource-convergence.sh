#!/bin/bash
# Plain-bash assertions for live resource-limit convergence decisions.
# Usage: bash tests/resource-convergence.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=../lib/resources.sh disable=SC1091
source "$SCRIPT_DIR/../lib/resources.sh"

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

_boxa::plan_resource_convergence boxa-app 536870912 536870912 536870912 536870912 400000000
assert_eq "matching limits skip update" "" "$_BOXA_RESOURCE_UPDATE_NEEDED"
assert_eq "matching limits print nothing" "" "$_BOXA_RESOURCE_UPDATE_NOTICE"
assert_eq "matching limits do not warn" "" "$_BOXA_RESOURCE_UPDATE_WARNING"

_boxa::plan_resource_convergence boxa-app 0 0 1073741824 1073741824 500000000
assert_eq "legacy unlimited Container needs update" "1" "$_BOXA_RESOURCE_UPDATE_NEEDED"
assert_eq "legacy migration notice" \
    "Memory limits updated for boxa-app: memory unlimited -> 1g; memory+swap unlimited -> 1g." \
    "$_BOXA_RESOURCE_UPDATE_NOTICE"
assert_eq "safe migration does not warn" "" "$_BOXA_RESOURCE_UPDATE_WARNING"

_boxa::plan_resource_convergence boxa-app 2147483648 3221225472 1073741824 1610612736 1500000000
assert_eq "changed memory and swap need update" "1" "$_BOXA_RESOURCE_UPDATE_NEEDED"
assert_eq "changed values appear in notice" \
    "Memory limits updated for boxa-app: memory 2g -> 1g; memory+swap 3g -> 1.5g." \
    "$_BOXA_RESOURCE_UPDATE_NOTICE"
assert_eq "lowering below usage warns" \
    "WARNING: boxa-app currently uses 1.4g, above its new 1g Memory limit; an immediate OOM kill may follow." \
    "$_BOXA_RESOURCE_UPDATE_WARNING"

_boxa::plan_resource_convergence boxa-app 1073741824 1073741824 2147483648 2147483648 3000000000
assert_eq "raising below current usage does not warn" "" "$_BOXA_RESOURCE_UPDATE_WARNING"

_boxa::plan_resource_convergence boxa-app 2147483648 3221225472 2147483648 2147483648 2500000000
assert_eq "swap-only convergence needs update" "1" "$_BOXA_RESOURCE_UPDATE_NEEDED"
assert_eq "swap-only lowering does not claim Memory-limit OOM risk" "" "$_BOXA_RESOURCE_UPDATE_WARNING"

_boxa::plan_resource_convergence boxa-app 0 0 1073741824 1073741824 500000000 1
assert_eq "one-shot notice points to durable config" \
    "Memory limits updated for boxa-app: memory unlimited -> 1g; memory+swap unlimited -> 1g. One-shot override; set ~/.config/boxa/resources.conf for a durable setting." \
    "$_BOXA_RESOURCE_UPDATE_NOTICE"

if [ "$fail_count" -gt 0 ]; then
    printf '\n%d test(s) failed.\n' "$fail_count" >&2
    exit 1
fi
printf '\nAll tests passed.\n'
