#!/bin/bash
# Plain-bash assertions for lib/mem-report.sh. Runs without Docker.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

export BOXA_OOM_ARCHIVE_DIR="$TEST_TMP/archive"
export BOXA_MEMORY_DOCS_URL="https://example.test/docs/memory"
export BOXA_RESOURCES_CONF="$TEST_TMP/resources.conf"
export BOXA_MEMINFO_FILE="$TEST_TMP/meminfo"
mkdir -p "$BOXA_OOM_ARCHIVE_DIR" "$TEST_TMP/My Project"
printf 'MemTotal:       10485760 kB\n' > "$BOXA_MEMINFO_FILE"

# shellcheck source-path=SCRIPTDIR source=../lib/naming.sh disable=SC1091
source "$SCRIPT_DIR/../lib/naming.sh"
# shellcheck source-path=SCRIPTDIR source=../lib/resources.sh disable=SC1091
source "$SCRIPT_DIR/../lib/resources.sh"
# shellcheck source-path=SCRIPTDIR source=../lib/mem-report.sh disable=SC1091
source "$SCRIPT_DIR/../lib/mem-report.sh"

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

_boxa::mem_resolve_target "" "$TEST_TMP/My Project"
assert_eq "no argument resolves cwd basename" "My-Project" "$_BOXA_MEM_PROJECT"
assert_eq "no argument preserves absolute path" "$TEST_TMP/My Project" "$_BOXA_MEM_PROJECT_PATH"
assert_eq "no argument derives container" "boxa-My-Project" "$_BOXA_MEM_CONTAINER"

_boxa::mem_resolve_target "$TEST_TMP/My Project" /irrelevant
assert_eq "explicit path resolves basename" "My-Project" "$_BOXA_MEM_PROJECT"
_boxa::mem_resolve_target "api_worker" /irrelevant
assert_eq "explicit name is sanitized" "api-worker" "$_BOXA_MEM_PROJECT"
assert_eq "explicit name has no guessed path" "" "$_BOXA_MEM_PROJECT_PATH"

assert_eq "parse numeric cgroup value" "536870912" "$(_boxa::mem_parse_cgroup_value 536870912)"
assert_eq "parse max as unlimited" "unlimited" "$(_boxa::mem_parse_cgroup_value max)"
assert_eq "parse inspect zero as unlimited" "unlimited" "$(_boxa::mem_parse_cgroup_value 0 true)"
assert_fail "reject malformed cgroup value" _boxa::mem_parse_cgroup_value nope
assert_eq "format bytes through resources helper" "512m" "$(_boxa::mem_format_value 536870912)"
assert_eq "format max as unlimited" "unlimited" "$(_boxa::mem_format_value max)"
assert_eq "format zero usage as zero" "0k" "$(_boxa::mem_format_value 0)"
assert_eq "format zero inspect limit as unlimited" "unlimited" "$(_boxa::mem_format_limit 0)"

assert_eq "percentage has one decimal" "25.0%" "$(_boxa::mem_percentage 268435456 1073741824)"
assert_eq "percentage handles unlimited" "n/a" "$(_boxa::mem_percentage 1 max)"
assert_eq "combined memory and swap limit" "1610612736" "$(_boxa::mem_combined_limit 1073741824 536870912)"
assert_eq "combined unlimited limit" "max" "$(_boxa::mem_combined_limit max 0)"

printf '%s\n' \
    'memory = 8g' \
    'memory_swap = 9g' \
    "[$TEST_TMP/My Project]" \
    'memory = 5g' > "$BOXA_RESOURCES_CONF"
_boxa::reset_resources_cache
effective_output=$(_boxa::mem_render_effective_limits "$TEST_TMP/My Project")
assert_eq "effective limits show independent sources and durable hint" \
    $'Effective Memory limit: 5g\nMemory limit source: project config\nEffective Memory+swap limit: 9g\nMemory+swap limit source: global config\nHint: use `boxa mem set` to change these limits durably.' \
    "$effective_output"

missing_path_output=$(_boxa::mem_render_effective_limits "")
assert_ok "missing absolute path keeps unavailable diagnosis" \
    grep -Fq "absolute project path unavailable" <<< "$missing_path_output"

printf '%s\n' "[$TEST_TMP/My Project]" 'memory = invalid' > "$BOXA_RESOURCES_CONF"
_boxa::reset_resources_cache
resolution_failure_output=$(_boxa::mem_render_effective_limits "$TEST_TMP/My Project" 2>&1)
assert_ok "effective limits surface invalid configured size" \
    grep -Fq "Invalid memory size 'invalid'" <<< "$resolution_failure_output"
assert_not_contains "resolution failure is not reported as an unavailable path" \
    "absolute project path unavailable" "$resolution_failure_output"

: > "$BOXA_RESOURCES_CONF"
rm -f "$BOXA_MEMINFO_FILE"
export BOXA_DOCKER_INFO_CMD=/bin/false
export BOXA_SYSCTL_CMD=/bin/false
_boxa::reset_resources_cache
resolution_failure_output=$(_boxa::mem_render_effective_limits "$TEST_TMP/My Project" 2>&1)
assert_ok "effective limits surface unavailable host RAM" \
    grep -Fq "Unable to determine host RAM" <<< "$resolution_failure_output"
assert_not_contains "host RAM failure is not reported as an unavailable path" \
    "absolute project path unavailable" "$resolution_failure_output"
printf 'MemTotal:       10485760 kB\n' > "$BOXA_MEMINFO_FILE"

events_output=$(_boxa::mem_render_events $'low 1\nhigh 2\nmax 3\noom 4\noom_kill 5')
assert_eq "render full memory.events" $'  low:      1\n  high:     2\n  max:      3\n  oom:      4\n  oom_kill: 5' "$events_output"
events_output=$(_boxa::mem_render_events $'oom_kill 2\nunknown 99')
assert_eq "missing event keys default to zero" $'  low:      0\n  high:     0\n  max:      0\n  oom:      0\n  oom_kill: 2' "$events_output"

printf 'Boxa OOM archive\nProject: api\n' > "$BOXA_OOM_ARCHIVE_DIR/boxa-api-10.100.log"
printf 'Boxa OOM archive\nProject: api\n' > "$BOXA_OOM_ARCHIVE_DIR/boxa-api-12.300.log"
printf 'wrong project\n' > "$BOXA_OOM_ARCHIVE_DIR/boxa-api-worker-99.900.log"
printf 'wrong grammar\n' > "$BOXA_OOM_ARCHIVE_DIR/boxa-api-latest.log"
archive_paths=$(_boxa::mem_archive_paths boxa-api 5)
assert_eq "archives newest first without prefix collision" \
    "$BOXA_OOM_ARCHIVE_DIR/boxa-api-12.300.log
$BOXA_OOM_ARCHIVE_DIR/boxa-api-10.100.log" "$archive_paths"
archive_output=$(_boxa::mem_render_archives boxa-api)
assert_ok "archive content is rendered" grep -Fq "Boxa OOM archive" <<< "$archive_output"

ps_output=$(_boxa::mem_render_ps $'PID PPID RSS COMMAND COMMAND\n42 1 524288 node node server.js\n7 1 1024 dockerd dockerd')
assert_ok "RSS listing uses resources formatter" grep -Fq "512m" <<< "$ps_output"
assert_ok "RSS listing remains project process data" grep -Fq "node server.js" <<< "$ps_output"

recommendations=$(_boxa::mem_render_recommendations api "$TEST_TMP/My Project" 8g)
assert_ok "known path is used for one-shot raise" \
    grep -Fq "boxa --memory 8g $TEST_TMP/My\\ Project" <<< "$recommendations"
assert_eq "recommended next commands block" "
Recommended next commands:
  Temporary raise (one shot): boxa --memory 8g $TEST_TMP/My\\ Project
  Durable raise: edit ~/.config/boxa/resources.conf and add:
    [$TEST_TMP/My Project]
    memory = 8g
    memory_swap = 8g
  Diagnose again: boxa mem $TEST_TMP/My\\ Project
  Docs: https://example.test/docs/memory" "$recommendations"

recommendations=$(_boxa::mem_render_recommendations api "" 12g)
assert_fail "removed container omits unusable one-shot raise" \
    grep -Fq "boxa --memory" <<< "$recommendations"
assert_ok "removed container keeps durable path hint" \
    grep -Fq "[/absolute/path/to/project]" <<< "$recommendations"
assert_eq "recommended size doubles current limit" "8g" "$(_boxa::mem_recommended_size 4294967296)"
assert_eq "removed container still gets concrete size" "12g" "$(_boxa::mem_recommended_size '')"

if [ "$fail_count" -gt 0 ]; then
    printf '\n%d test(s) failed.\n' "$fail_count" >&2
    exit 1
fi
printf '\nAll mem-report tests passed.\n'
