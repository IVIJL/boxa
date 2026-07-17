#!/bin/bash
# Plain-bash assertions for lib/resources.sh. Runs without Docker.
# Usage: bash tests/resources.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=../lib/resources.sh disable=SC1091
source "$SCRIPT_DIR/../lib/resources.sh"

_TMPROOT="$(mktemp -d)"
export BOXA_RESOURCES_CONF="$_TMPROOT/resources.conf"
export BOXA_MEMINFO_FILE="$_TMPROOT/meminfo"
export BOXA_RUNNING_MEMORY_LIMITS_FILE="$_TMPROOT/running-limits"
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

assert_ok() {
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        printf 'PASS  %s\n' "$label"
    else
        printf 'FAIL  %s\n      expected success\n' "$label"
        fail_count=$((fail_count + 1))
    fi
}

assert_fail() {
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        printf 'FAIL  %s\n      expected failure\n' "$label"
        fail_count=$((fail_count + 1))
    else
        printf 'PASS  %s\n' "$label"
    fi
}

seed_conf() {
    _boxa::reset_resources_cache
    : > "$BOXA_RESOURCES_CONF"
    local line
    for line in "$@"; do
        printf '%s\n' "$line" >> "$BOXA_RESOURCES_CONF"
    done
}

set_host_gib() {
    local gib="$1"
    printf 'MemTotal:       %s kB\n' "$((gib * 1024 * 1024))" > "$BOXA_MEMINFO_FILE"
}

resolve_ok() {
    _boxa::resolve_resources "$@"
}

set_host_gib 10
: > "$BOXA_RUNNING_MEMORY_LIMITS_FILE"

# --- Size parser ------------------------------------------------------------

assert_eq "parse 512m"  "536870912"  "$(_boxa::parse_size 512m)"
assert_eq "parse 5g"    "5368709120" "$(_boxa::parse_size 5g)"
assert_eq "parse 6GiB"  "6442450944" "$(_boxa::parse_size 6GiB)"
assert_eq "parse 6MB"   "6291456"    "$(_boxa::parse_size 6MB)"
assert_ok "accept exact 6 MiB floor" _boxa::parse_size 6m
assert_fail "reject below 6 MiB" _boxa::parse_size 5m
assert_fail "reject zero" _boxa::parse_size 0g
assert_fail "reject negative" _boxa::parse_size -1g
assert_fail "reject garbage" _boxa::parse_size nonsense
assert_fail "reject missing unit" _boxa::parse_size 512

# --- Strict config parser ---------------------------------------------------

marker="$_TMPROOT/should-not-exist"
seed_conf \
    "memory = 7g" \
    "memory_swap=8g" \
    "unknown_key=99g" \
    "evil=\$(touch $marker)" \
    "[/work/other]" \
    "memory=6g" \
    "memory_swap = 6GiB"
resolve_ok /work/other
assert_eq "project memory parsed" "6442450944" "$_BOXA_MEMORY_BYTES"
assert_eq "project memory_swap parsed" "6442450944" "$_BOXA_MEMORY_SWAP_BYTES"
assert_eq "project source" "project config" "$_BOXA_MEMORY_SOURCE"
assert_eq "config is never sourced" "absent" "$([ -e "$marker" ] && printf present || printf absent)"

resolve_ok /work/global
assert_eq "global memory parsed" "7516192768" "$_BOXA_MEMORY_BYTES"
assert_eq "global memory_swap parsed" "8589934592" "$_BOXA_MEMORY_SWAP_BYTES"
assert_eq "global source" "global config" "$_BOXA_MEMORY_SOURCE"

# --- Precedence and derived default ----------------------------------------

resolve_ok /work/other 9g 10g
assert_eq "CLI memory wins" "9663676416" "$_BOXA_MEMORY_BYTES"
assert_eq "CLI memory_swap wins" "10737418240" "$_BOXA_MEMORY_SWAP_BYTES"
assert_eq "CLI source" "CLI flag" "$_BOXA_MEMORY_SOURCE"

seed_conf "memory=7g" "[/work/project]" "memory=6g"
resolve_ok /work/project
assert_eq "section beats global" "6442450944" "$_BOXA_MEMORY_BYTES"
assert_eq "missing memory_swap defaults to memory" "6442450944" "$_BOXA_MEMORY_SWAP_BYTES"

seed_conf
resolve_ok /work/default
assert_eq "derived default is 65 percent" "6979321856" "$_BOXA_MEMORY_BYTES"
assert_eq "derived source" "derived" "$_BOXA_MEMORY_SOURCE"
assert_eq "derived swap defaults to memory" "6979321856" "$_BOXA_MEMORY_SWAP_BYTES"
assert_eq "derived startup display" "6.5g" "$(_boxa::format_size "$_BOXA_MEMORY_BYTES")"

# --- Validation -------------------------------------------------------------

seed_conf "memory=7g" "memory_swap=6g"
assert_fail "reject memory_swap below memory" _boxa::resolve_resources /work/project

seed_conf "memory=5m"
assert_fail "reject configured value below floor" _boxa::resolve_resources /work/project

seed_conf "memory=garbage"
assert_fail "reject invalid configured value" _boxa::resolve_resources /work/project

seed_conf "memory="
assert_fail "reject empty configured value" _boxa::resolve_resources /work/project

seed_conf "memory=7g" "[relative/path]" "memory=9g"
resolve_ok /work/project
assert_eq "relative section is ignored, not global" "7516192768" "$_BOXA_MEMORY_BYTES"

# --- Running-container sum seam --------------------------------------------

printf '%s\n' 2147483648 3221225472 0 > "$BOXA_RUNNING_MEMORY_LIMITS_FILE"
assert_eq "sum running limits" "5368709120" "$(_boxa::running_memory_limit_sum)"
assert_ok "joint exhaustion detected" _boxa::would_jointly_exhaust_host 6442450944 10737418240
assert_fail "sum within host RAM" _boxa::would_jointly_exhaust_host 4294967296 10737418240

# --- `boxa ls` MEM cell -------------------------------------------------------

assert_eq "mem cell usage/limit percent" "2.3g/6.5g 35%" \
    "$(_boxa::mem_cell $'2469606195\n6979321856\n0')"
assert_eq "mem cell rounds percent to nearest" "2g/3g 67%" \
    "$(_boxa::mem_cell $'2147483648\n3221225472\n0')"
assert_eq "mem cell appends oom marker with count" "512m/1g 50% !oom×3" \
    "$(_boxa::mem_cell $'536870912\n1073741824\n3')"
assert_eq "mem cell limitless" "no limit" \
    "$(_boxa::mem_cell $'1073741824\nmax\n0')"
assert_eq "mem cell limitless keeps oom marker" "no limit !oom×2" \
    "$(_boxa::mem_cell $'1073741824\nmax\n2')"
assert_eq "mem cell empty probe degrades" "-" "$(_boxa::mem_cell '')"
assert_eq "mem cell partial probe degrades" "-" "$(_boxa::mem_cell $'123')"
assert_eq "mem cell garbage probe degrades" "-" \
    "$(_boxa::mem_cell 'cat: /sys/fs/cgroup/memory.current: No such file')"
assert_eq "mem cell zero max degrades" "-" "$(_boxa::mem_cell $'1\n0\n0')"
assert_eq "mem cell non-numeric oom count degrades" "-" \
    "$(_boxa::mem_cell $'1073741824\nmax\nnope')"

# --- Exited-Container OOM marker ---------------------------------------------

assert_eq "exited marker on lifetime flag" \
    "oom seen during run — see 'boxa mem foo'" \
    "$(_boxa::exited_oom_marker true foo)"
assert_eq "exited marker silent when false" "" \
    "$(_boxa::exited_oom_marker false foo)"
assert_eq "exited marker silent when flag missing" "" \
    "$(_boxa::exited_oom_marker '' foo)"

if [ "$fail_count" -gt 0 ]; then
    printf '\n%d test(s) failed.\n' "$fail_count" >&2
    exit 1
fi
printf '\nAll tests passed.\n'
