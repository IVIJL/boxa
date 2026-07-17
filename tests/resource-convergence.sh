#!/bin/bash
# Plain-bash assertions for live resource-limit convergence decisions.
# Usage: bash tests/resource-convergence.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOXA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=../lib/resources.sh disable=SC1091
source "$SCRIPT_DIR/../lib/resources.sh"

_TMPROOT="$(mktemp -d)"
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

_boxa::plan_resource_convergence boxa-app 2147483648 2147483648 1073741824 1073741824 ""
assert_eq "stopped Container with no usage does not warn" "" "$_BOXA_RESOURCE_UPDATE_WARNING"

# docker-run.sh is not source-safe, so extract only the restart helper and
# verify its stopped-Container convergence wiring with mocked dependencies.
extracted="$_TMPROOT/restart_exited_container.sh"
awk '
    /^restart_exited_container\(\) \{$/ { capture=1 }
    capture { print }
    capture && /^\}$/ { exit }
' "$BOXA_DIR/docker-run.sh" > "$extracted"

if [ ! -s "$extracted" ]; then
    printf 'FAIL  could not extract restart_exited_container from docker-run.sh\n'
    fail_count=$((fail_count + 1))
else
    # shellcheck source=/dev/null
    source "$extracted"
    calls="$_TMPROOT/restart.calls"
    : > "$calls"
    DNS_UPSTREAM_CONTAINER_FILE=/etc/boxa-shared/docker-dns-upstream.conf

    # shellcheck disable=SC2317
    docker() {
        if [ "$1" = inspect ]; then
            printf '%s\n' "$DNS_UPSTREAM_CONTAINER_FILE"
        else
            printf 'docker:%s\n' "$*" >> "$calls"
        fi
    }
    # shellcheck disable=SC2317
    write_dns_upstream_file() { printf '%s\n' write-dns >> "$calls"; }
    # shellcheck disable=SC2317
    _boxa::converge_container_resources() { printf 'converge:%s\n' "$*" >> "$calls"; }
    # shellcheck disable=SC2317
    wait_for_boxa_ready() { :; }
    # shellcheck disable=SC2317
    warn_if_dns_broken() { :; }
    # shellcheck disable=SC2317
    apply_port_routes() { :; }
    # shellcheck disable=SC2317
    start_boxa_connections() { :; }

    restart_exited_container boxa-app /work/app 2g 3g >/dev/null
    restart_calls="$(< "$calls")"
    assert_eq "stopped Container converges before docker start" \
        $'write-dns\nconverge:boxa-app /work/app 2g 3g stopped\ndocker:start boxa-app\ndocker:exec -u node boxa-app bash -c /usr/local/bin/start-rootless-docker.sh && /usr/local/bin/setup-chezmoi.sh && /usr/local/bin/setup-claude.sh' \
        "$restart_calls"
fi

if [ "$fail_count" -gt 0 ]; then
    printf '\n%d test(s) failed.\n' "$fail_count" >&2
    exit 1
fi
printf '\nAll tests passed.\n'
